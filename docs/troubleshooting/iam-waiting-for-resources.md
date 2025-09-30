# IAM application stuck on `waiting for resources`

## Symptoms

* Argo CD shows the `iam` application with `phase=Running`, `sync=OutOfSync` or `sync=Synced` but the last
  operation message reads `waiting for resources`.
* The operation state lists the `batch/Job: midpoint-seeder` resource as pending or running for an extended
  period of time.
* `kubectl get jobs midpoint-seeder -n iam` reports the job as `Active`, and its logs repeat
  `midPoint not ready yet (HTTP 503)` or similar messages.

## Why this happens

The IAM kustomization seeds demo objects into midPoint using a PostSync job. Argo CD waits for this job to
finish before it can mark the application healthy. The job polls the midPoint REST endpoint until it receives
an HTTP 200 response. When midPoint is unhealthy—because the pod is still starting, the database connection
fails, or the administrator credentials are incorrect—the job keeps retrying and Argo CD keeps reporting
`waiting for resources`.

The seeder job now fails fast when the REST API returns HTTP 401/403 (invalid admin credentials) or HTTP 404
(incorrect service URL). These errors typically point to a misconfigured `midpoint-admin` secret or an
unexpected service address.

## Gather diagnostics first

Run the helper script to capture the current Argo CD state, job logs, midPoint pod status and the
CloudNativePG resources:

```bash
./scripts/collect_midpoint_diagnostics.sh
```

Focus on the following sections of the output:

* **Seeder job logs** – repeated HTTP status codes show whether the job can reach the REST API and whether the
  credentials are valid. If you see `HTTP 401` or `HTTP 403`, the administrator password in the
  `midpoint-admin` secret is wrong. `HTTP 404` indicates the job cannot reach the `/ws/rest/version` endpoint
  at the expected service name.
* **midPoint pod init containers** – look for failures in the `midpoint-db-wait`, `repo-init` or
  `midpoint-db-init` init containers. They surface database connectivity issues and schema bootstrap errors.
* **CloudNativePG cluster and database resources** – confirm the `iam-db` cluster is `Ready` and the
  `database/midpoint` custom resource reports `DatabaseReady` in its conditions.

Collecting this information ensures we understand whether the failure is caused by midPoint startup issues,
database availability or incorrect credentials before applying a fix.

## Proposed fix – Attempt 1

**Goal:** bring midPoint to a healthy state so the seeder job can complete successfully.

1. **Fix credential mismatches first.** If the job fails immediately with `HTTP 401` or `HTTP 403`, update the
   `midpoint-admin` secret in [`gitops/apps/iam/secrets/kustomization.yaml`](../../gitops/apps/iam/secrets/kustomization.yaml)
   with the correct administrator password and commit the change. Argo CD will recreate the secret and the next
   seeder job run will succeed.
2. **Investigate midPoint pod failures.** When the init containers fail, inspect their logs for errors such as
   `timed out waiting for PostgreSQL` or SQL exceptions. Resolve database availability issues by ensuring the
   CloudNativePG cluster (`kubectl get cluster iam-db -n iam`) reports `Ready` and that the managed roles exist.
   If the repository bootstrap fails due to data drift, consider resetting the cluster or restoring from a
   known-good backup.
3. **Verify service reachability.** If the job reports `HTTP 404`, confirm the `MIDPOINT_URL` value points to
   the in-cluster service (`http://midpoint:8080/midpoint`). Check for stray overrides in the job environment or
   service name changes in [`gitops/apps/iam/midpoint/deployment.yaml`](../../gitops/apps/iam/midpoint/deployment.yaml).

After applying the fix, delete the existing seeder job (or allow Argo CD to recreate it during the next sync)
so it runs with the corrected configuration:

```bash
kubectl delete job midpoint-seeder -n iam
argocd app sync iam
```

The IAM application should leave the `waiting for resources` state once the midPoint pods reach `Ready` and the
seeder job completes successfully.
