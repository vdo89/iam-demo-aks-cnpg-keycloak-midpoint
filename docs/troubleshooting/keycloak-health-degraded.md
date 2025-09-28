# Keycloak health endpoint reports `NOT READY`

> ℹ️ If the Keycloak pod exits immediately with `ExitCode: 2` and the controller reports `CrashLoopBackOff`,
> follow [Keycloak pod stuck in `CrashLoopBackOff`](./keycloak-crashloop.md) instead. The steps below assume the
> server is running but the readiness probe is failing.

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

* **Database connectivity:** Verify the CloudNativePG generated `iam-db-app` secret contains a working password for the `app` user. Keycloak now consumes that secret directly, so a mismatch indicates the database user was changed manually. To confirm the credentials quickly:
  1. Decode the credentials that Keycloak consumes:
     ```bash
     kubectl -n iam get secret iam-db-app \
       -o jsonpath='{.data.username}' | base64 -d; echo
     kubectl -n iam get secret iam-db-app \
       -o jsonpath='{.data.password}' | base64 -d; echo
     ```
  2. Test those credentials against the CloudNativePG primary:
     ```bash
     USER=$(kubectl -n iam get secret iam-db-app -o jsonpath='{.data.username}' | base64 -d)
     PASS=$(kubectl -n iam get secret iam-db-app -o jsonpath='{.data.password}' | base64 -d)

     kubectl -n iam run -it --rm pgclient \
       --image=ghcr.io/cloudnative-pg/postgresql:16.4 -- \
       bash -lc "export PGPASSWORD='$PASS'; psql -h iam-db-rw.iam.svc.cluster.local -U '$USER' -d keycloak -c '\\conninfo'"
     ```
  3. If the command returns `\conninfo` without an error, the credentials are correct; otherwise update either the database user or the secret so that they match.
* **TLS enforcement errors:** If the readiness payload or Keycloak logs mention `SSL off` or a missing `pg_hba.conf` entry, confirm the `Keycloak` manifest still declares `spec.db.urlProperties: "?sslmode=require"`. The operator concatenates that value onto the JDBC URL; omitting the leading `?` produces a database name such as `keycloaksslmode=require`, which fails with `FATAL: database "keycloaksslmode=require" does not exist`. Keeping the delimiter ensures every connection negotiates TLS when CloudNativePG requires encryption.
* **Schema migrations:** Monitor the pod logs until migrations complete. Large schema updates can temporarily keep the readiness probe `DOWN`; do not restart the pod unless the logs show a fatal error.
* **Missing secrets or config:** Confirm every reference in `gitops/apps/iam/keycloak/keycloak.yaml` and the realm import exists in the `iam` namespace. Re-run the bootstrap workflow if secrets are missing.

Once the `/health/ready` endpoint reports `UP`, the operator marks the CR as ready and Argo CD converges without manual intervention.
