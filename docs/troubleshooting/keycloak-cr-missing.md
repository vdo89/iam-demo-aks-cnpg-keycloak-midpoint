# Keycloak custom resource missing

## Symptoms

* Argo CD shows the `Keycloak` resource as `OutOfSync` or pruned inside the `iam` application summary.
* `kubectl get keycloak rws-keycloak -n iam` returns `Error from server (NotFound)`.
* The diagnostics script reports `Keycloak custom resource` and `Describe Keycloak custom resource` failures.
* No Keycloak StatefulSet or pods exist in the `iam` namespace.

## Why this happens

The Keycloak operator only creates the StatefulSet after the `Keycloak` custom resource exists. If the CR is deleted—or if
Argo CD never applied it because the operator CRDs were missing—the operator has nothing to reconcile. Argo CD will continue
showing the resource as missing until the manifest is applied successfully.

## Gather context first

Run `./scripts/collect_keycloak_diagnostics.sh`. When the CR is missing the script highlights the failed `kubectl get` calls
and lists the current pods in the namespace. Keep this output for the incident record.

If you prefer to run the commands manually:

```bash
kubectl get application iam -n argocd -o json \
  | jq '.status.operationState.syncResult.resources[]? | select(.kind == "Keycloak")'

kubectl get keycloak rws-keycloak -n iam -o yaml
kubectl describe keycloak rws-keycloak -n iam
kubectl get pods -n iam --show-labels
```

## Fix the root cause

1. **Confirm the operator is installed** – The CRDs must exist before Argo CD can apply the Keycloak manifest. Verify that the
   `keycloak-operator` application is `Healthy` and that the `keycloaks.k8s.keycloak.org` CRD is present:
   ```bash
   argocd app wait keycloak-operator --health --timeout 180
   kubectl get crd keycloaks.k8s.keycloak.org keycloakrealmimports.k8s.keycloak.org
   ```
2. **Resync the IAM application** – If the operator is ready, instruct Argo CD to reapply the Keycloak manifest. This recreates
   the CR when it was deleted manually or after the first attempt failed because the CRDs were missing:
   ```bash
   argocd app sync iam --resource k8s.keycloak.org/Keycloak:iam/rws-keycloak
   ```
3. **Investigate persistent failures** – When the sync fails again, inspect the Argo CD operation state to find the recorded error
   (for example `no matches for kind "Keycloak"`). Capture the Keycloak operator logs for the same time window—they confirm
   whether the CRD installation or reconciliation failed:
   ```bash
   kubectl logs deployment/keycloak-operator -n iam --since=15m
   ```
4. **Document the outcome** – Once the CR appears again (`kubectl get keycloak -n iam`) and the operator creates the StatefulSet,
   note the resolution in the incident tracker so future responders know the recovery steps.

Following this sequence ensures the operator dependencies are satisfied before asking Argo CD to recreate the custom resource.
