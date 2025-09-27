# Keycloak health endpoint reports `NOT READY`

## Symptoms

* The Argo CD application shows the IAM stack as `sync=OutOfSync`, `health=Degraded`, `phase=Running`.
* The last sync message reads `waiting for healthy state of k8s.keycloak.org/Keycloak/rws-keycloak`.
* The Keycloak custom resource has a `Ready` condition with `status=False` and a reason mentioning health or readiness.

## Why this happens

The Keycloak operator marks the custom resource as `Ready` only after the `/health/ready` probe returns `UP` for the `keycloak` check. When that endpoint reports `DOWN`, the operator keeps the CR in a progressing state and Argo CD waits forever. According to the [Keycloak health checks documentation](https://www.keycloak.org/observability/health), common causes include:

* Database connectivity failures (for example, invalid credentials or unreachable host).
* Pending schema migrations when the database is still initialising.
* Missing configuration or secrets referenced by the CR.

## Gather diagnostics first

Run the helper script to collect all relevant state before attempting a fix:

```bash
./scripts/collect_keycloak_diagnostics.sh
```

The script now captures:

* The Keycloak CR status and controller events.
* The Keycloak pod descriptions and the last 200 log lines from each pod (look for `Health endpoint check result` entries).
* The live output of the `/health`, `/health/live`, `/health/ready`, and `/health/started` management endpoints from every Keycloak pod.
* Operator logs from the last 15 minutes.

Attach this output to the incident so future runs stay actionable.

## Manually query the health endpoint

1. Port-forward the HTTP service:
   ```bash
   kubectl port-forward svc/rws-keycloak-service -n iam 8080:8080
   ```
2. Check the readiness endpoint:
   ```bash
   curl -s http://localhost:8080/health/ready | jq
   ```
3. If the `keycloak` check reports `DOWN`, inspect the accompanying message. Database errors typically mention failing to open JDBC connections. Resolve the underlying issue (credentials, host reachability, pending migrations) and re-check the endpoint.

For more examples of response payloads, consult the [Keycloak health documentation](https://www.keycloak.org/observability/health).

## Apply the fix

* **Database connectivity:** Verify the `keycloak-db-app` secret values match the CloudNativePG database user. Reset the password via the CNPG management tooling and update the secret if necessary.
* **Schema migrations:** Monitor the pod logs until migrations complete. Large schema updates can temporarily keep the readiness probe `DOWN`; do not restart the pod unless the logs show a fatal error.
* **Missing secrets or config:** Confirm every reference in `gitops/apps/iam/keycloak/keycloak.yaml` and the realm import exists in the `iam` namespace. Re-run the bootstrap workflow if secrets are missing.

Once the `/health/ready` endpoint reports `UP`, the operator marks the CR as ready and Argo CD converges without manual intervention.
