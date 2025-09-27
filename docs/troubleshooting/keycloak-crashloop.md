# Keycloak pod stuck in `CrashLoopBackOff`

## Symptoms

* The Keycloak StatefulSet pods restart repeatedly with `ExitCode: 2` within a few seconds.
* `kubectl describe pod rws-keycloak-0 -n iam` shows the Keycloak container waiting with the reason `CrashLoopBackOff`.
* The Keycloak operator controller logs report `Found unhealthy container on pod iam/rws-keycloak-0`.

## Why this happens

An exit code of `2` means the Keycloak bootstrap script failed before the server started. In practice this is almost
always caused by an invalid CLI flag passed through `spec.additionalOptions`. In the 26.x releases the server rejects
unknown management options such as `--http-management-allowed-hosts` and terminates immediately, which matches the
behaviour seen in incident IAM-1137.

## Gather diagnostics first

Run the helper script to capture the full context (pod descriptions, current and previous logs, operator output, and
management endpoints):

```bash
./scripts/collect_keycloak_diagnostics.sh
```

Look for log lines similar to the following in the `previous container` section for the crashing pod:

```
Unknown option: '--http-management-allowed-hosts'
```

## Apply the fix

Remove the invalid option from `gitops/apps/iam/keycloak/keycloak.yaml`. The operator will roll out a new pod that starts
successfully with the remaining management options (`--http-management-enabled` and `--http-management-host=0.0.0.0`). No
additional configuration is required because the management service already binds to all network interfaces.

If a future version of Keycloak introduces a replacement flag, add it back only after confirming it appears in the
[official configuration reference](https://github.com/keycloak/keycloak/blob/main/docs/guides/server/all-config.adoc).
