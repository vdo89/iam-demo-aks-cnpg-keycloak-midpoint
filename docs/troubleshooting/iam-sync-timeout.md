# IAM application sync timeout runbook

## Symptoms

* Argo CD shows the `iam` application as `sync=OutOfSync`, `health=Degraded`, `phase=Running`.
* The Argo CD UI or `argocd app get iam` reports the last operation message similar to:
  `one or more synchronization tasks are not valid due to application controller sync timeout`.
* Repeated retries do not make progress (`Retrying attempt #<n>`), even after increasing the sync timeout.

## Why longer timeouts do not help

The controller marks a sync operation as *invalid* when it tries to apply resources whose CustomResourceDefinitions (CRDs)
are still missing. The controller retries while waiting for the CRDs to appear, but once the retry window expires it
aborts the sync. Because the CRDs never became available, giving the controller more time only produces longer stalls.

In the IAM stack this happens when the `iam` application starts syncing before the Keycloak operator finishes installing
its CRDs. The controller cannot create `Keycloak` or `KeycloakRealmImport` resources without those CRDs, so it continually
retries and eventually times out.

## Collect the right evidence

Run `scripts/collect_keycloak_diagnostics.sh` to capture the key Argo CD and Kubernetes state when the timeout occurs. The script
gathers the IAM and Keycloak operator application status, the operation state that lists invalid tasks, the presence of the
Keycloak CRDs, and recent operator logs so you can attach them to an incident or support ticket. If you prefer to run the
commands manually, follow the steps below.

1. Confirm the status and last operation details:
   ```bash
   argocd app get iam
   ```
2. Inspect the recorded operation state and invalid tasks:
   ```bash
   kubectl get application iam -n argocd -o json \
     | jq '.status.operationState | {phase, message, syncResult: .syncResult.resources[]? | select(.status == "OutOfSync")}'
   ```
3. Check whether the Keycloak operator application has finished reconciling:
   ```bash
   argocd app wait keycloak-operator --health --timeout 180
   ```
4. Make sure the Keycloak CRDs actually exist in the cluster:
   ```bash
   kubectl get crd keycloaks.k8s.keycloak.org keycloakrealmimports.k8s.keycloak.org
   ```
5. If the CRDs are missing, inspect the operator controller logs for installation errors:
   ```bash
   kubectl logs deployment/keycloak-operator -n keycloak --since=15m
   ```

Collecting this data before attempting a fix ensures we know whether the failure is caused by missing CRDs or by a different
error inside the operator.

## Proposed fix – Attempt 1

**Goal:** ensure the Keycloak operator (and its CRDs) are installed before Argo CD attempts to sync the IAM application.

**Change:** add Argo CD sync waves so that the parent app-of-apps applies the `keycloak-operator` application before the
`iam` application. Once the operator completes, the CRDs are available and the IAM sync can proceed.

**Implementation steps:**

1. Annotate `gitops/clusters/aks/apps/keycloak-operator.application.yaml` with `argocd.argoproj.io/sync-wave: "10"`.
2. Annotate `gitops/clusters/aks/apps/iam.application.yaml` with `argocd.argoproj.io/sync-wave: "30"`.
3. Commit the change and allow Argo CD to resync the parent application. The new ordering ensures the IAM application waits
   for the operator to finish creating its CRDs before reconciling Keycloak custom resources.

If the IAM application still fails after the sync-wave change, revisit the evidence above—specifically the operator logs and
the presence of CRDs—to determine whether the operator itself failed to install or if a different dependency (for example the
CloudNativePG operator) is missing. Document those findings before attempting a second fix.
