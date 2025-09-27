# Keycloak pod stuck in `CrashLoopBackOff`

## Symptoms

* The Keycloak StatefulSet pods restart repeatedly with `ExitCode: 2` within a few seconds.
* `kubectl describe pod rws-keycloak-0 -n iam` shows the Keycloak container waiting with the reason `CrashLoopBackOff`.
* The Keycloak operator controller logs report `Found unhealthy container on pod iam/rws-keycloak-0`.

## Why this happens

An exit code of `2` means the Keycloak bootstrap script failed before the server started. Two recurring issues trigger
this behaviour:

1. **Invalid CLI flags** – the 26.x releases reject unknown management options such as
   `--http-management-allowed-hosts` and terminate immediately. This matches the behaviour seen in incident IAM-1137.
2. **Accidentally running with `--optimized` on the first boot** – recent Keycloak images now refuse to start when the
   optimized path is enabled before the server has been built. The container exits immediately with the message:

   ```
   The '--optimized' flag was used for first ever server start. Please don't use this flag for the first startup or use
   'kc.sh build' to build the server first.
   ```

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

### 1. Remove invalid CLI flags

If the logs show `Unknown option: '--http-management-allowed-hosts'`, delete the invalid option from
`gitops/apps/iam/keycloak/keycloak.yaml`. The operator will roll out a new pod that starts successfully with the
remaining management options (`--http-management-enabled` and `--http-management-host=0.0.0.0`). No additional
configuration is required because the management service already binds to all network interfaces.

If a future version of Keycloak introduces a replacement flag, add it back only after confirming it appears in the
[official configuration reference](https://github.com/keycloak/keycloak/blob/main/docs/guides/server/all-config.adoc).

### 2. Disable the optimized start path for the first boot

If the logs contain the `The '--optimized' flag was used for first ever server start` warning, ensure that the
`Keycloak` resource keeps `spec.startOptimized: false` until the server has completed its initial build. Update
`gitops/apps/iam/keycloak/keycloak.yaml` if necessary, commit the change, and let Argo CD reconcile the new manifest.
The operator will restart the StatefulSet with `kc.sh start` (without the optimized flag), allowing the bootstrap to
finish successfully. After the first boot you can optionally build a custom image and flip `startOptimized` back to
`true` for faster restarts.
