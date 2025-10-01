# Keycloak service reconciliation conflict

## Symptoms

* The Keycloak operator reports an error while reconciling `KeycloakServiceDependentResource`.
* The controller logs include `Operation cannot be fulfilled on services "rws-keycloak-service": the object has been modified; please apply your changes to the latest version and try again`.
* Argo CD continuously flips the `rws-keycloak-service` manifest back to the Git state while the operator tries to apply its own changes.

## Why this happens

The upstream Keycloak operator already creates and manages the HTTP Service named `<keycloak-name>-service`. When the GitOps tree also defines a Service with the same name, two controllers attempt to own the same resource. Every time Argo CD reapplies the manifest from Git, the operator's next patch uses an out-of-date `resourceVersion` and fails with a 409 conflict.

## Fix

Remove the duplicate Service from Git so that the operator is the only controller managing it. After pruning the manifest:

1. Re-sync the IAM application in Argo CD. The operator will immediately recreate the Service with its desired annotations and ports.
2. Confirm that the Service exposes the expected ports (`80`, `8080`, and `9000`) by running:
   ```bash
   kubectl -n iam get svc rws-keycloak-service -o wide
   ```
3. Retry the original operation; the operator should now reconcile without conflicts.

Going forward, customise Keycloak's HTTP endpoints via the `Keycloak` custom resource (for example, by toggling `spec.http.httpEnabled` or the management options) instead of redefining the Service directly.
