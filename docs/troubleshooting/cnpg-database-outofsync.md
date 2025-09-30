# CloudNativePG Database stuck `OutOfSync`

## Symptoms

* Argo CD shows the IAM application `sync=OutOfSync` with drift on `postgresql.cnpg.io/Database` objects.
* Admission controllers or the operator continuously revert `spec.ensure` or `spec.databaseReclaimPolicy` to their defaults.
* Downstream components (for example, Keycloak) report readiness failures because the database CR never reconciles.

## Why this happens

CloudNativePG sets sensible defaults (`ensure: present`, `databaseReclaimPolicy: retain`, etc.) on the server side. When those
fields are not declared in Git, Argo CD detects drift after every reconciliation. The Database controller still converges, but
Argo keeps toggling between `Synced` and `OutOfSync`, which can mask genuine issues during incident response.

## Remediation

1. **Prefer server-side apply for the entire IAM application.** This allows admission webhooks and the operator to default
   resources without creating false diffs.
   ```yaml
   spec:
     syncPolicy:
       syncOptions:
         - ServerSideApply=true
   ```
   The IAM application already sets this option, so no extra change is required when bootstrapping a fresh environment.
2. **If only specific resources drift, enable SSA per-resource** by annotating the manifest:
   ```yaml
   metadata:
     annotations:
       argocd.argoproj.io/sync-options: ServerSideApply=true
   ```
3. **As a last resort, ignore the known defaulted paths** once you have confirmed that the defaults are benign:
   ```yaml
   spec:
     ignoreDifferences:
       - group: postgresql.cnpg.io
         kind: Database
         jsonPointers:
           - /spec/ensure
           - /spec/databaseReclaimPolicy
   ```

## Ordering matters

Make sure the CNPG `Cluster` reconciles before any `Database` custom resources. Use sync waves to enforce ordering:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "10"   # Cluster
```

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "20"   # Database
```

Lower numbers apply first. This guarantees the cluster is ready before the database CRs attempt to connect.

## Quick health checks

Run these commands to validate the operator and the database status:

```bash
kubectl -n cnpg-system get deploy,pods
kubectl get crd | grep postgresql.cnpg.io
kubectl -n iam get cluster
kubectl -n iam get secret keycloak-db-app
kubectl -n iam describe database keycloak
kubectl -n iam get database keycloak -o yaml | yq '.status'
```

A reconciled Database reports `status.applied: true` and `status.observedGeneration` matching `metadata.generation`. If Keycloak
is still `DOWN`, follow the dedicated [Keycloak health degraded runbook](./keycloak-health-degraded.md) to inspect the readiness
probe and database connectivity.

## Need more help?

Share the output of:

```bash
kubectl -n iam get database keycloak midpoint -o yaml
```

Include the resulting `spec` and `status` in your incident notes so reviewers can pinpoint the exact field that keeps drifting and
suggest a focused patch.
