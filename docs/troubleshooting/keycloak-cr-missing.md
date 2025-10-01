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

Run `./scripts/collect_keycloak_diagnostics.sh`. When the CR is missing the script highlights the failed `kubectl get` calls,
lists the current pods in the namespace, and captures the state of any `KeycloakRealmImport` resources or jobs that may be
waiting for the Keycloak server to exist. Keep this output for the incident record.

If you prefer to run the commands manually:

```bash
kubectl get application iam -n argocd -o json \
  | jq '.status.operationState.syncResult.resources[]? | select(.kind == "Keycloak")'

kubectl get keycloak rws-keycloak -n iam -o yaml
kubectl describe keycloak rws-keycloak -n iam
kubectl get keycloakrealmimports -n iam -o wide
kubectl get jobs -n iam -l app=keycloak-realm-import --show-labels
kubectl get pods -n iam --show-labels
```

## Quick recovery checklist

1. **Verify the operator finished installing**
   * `argocd app wait keycloak-operator --health --timeout 180`
   * `kubectl get crd keycloaks.k8s.keycloak.org keycloakrealmimports.k8s.keycloak.org`
2. **Recreate the Keycloak custom resource** (pick the option that matches your access)
   * Argo CD CLI: `argocd app sync iam --resource k8s.keycloak.org/Keycloak:iam/rws-keycloak`
   * Argo CD UI: select the Keycloak resource inside the `iam` application and press **Sync**
   * kubectl: `kubectl apply -f gitops/apps/iam/keycloak/keycloak.yaml`
3. **Confirm the resource exists again**
   * `kubectl get keycloak rws-keycloak -n iam`
   * Wait for the operator to create the StatefulSet and pods (`kubectl get pods -n iam -l app=keycloak`)
4. **Capture evidence**
   * On repeated failures, inspect the Argo CD operation message for errors such as `no matches for kind "Keycloak"`
   * Pull the operator logs for the same window: `kubectl logs deployment/keycloak-operator -n iam --since=15m`
5. **Update the incident record**
   * Note the recovery command you used and whether further follow-up is required so future responders have the full context

Following this sequence ensures the operator dependencies are satisfied before asking Argo CD to recreate the custom resource.
