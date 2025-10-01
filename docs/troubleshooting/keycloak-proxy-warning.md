# Keycloak reports insecure proxy headers configuration

## Symptoms

* Keycloak pod logs include warnings similar to:
  ```
  WARNING: Likely misconfiguration detected. With HTTPS not enabled, `proxy-headers` unset, and a non-URL `hostname`, the server is running in an insecure context.
  WARNING: Hostname v1 options [hostname-strict-backchannel] are still in use, please review your configuration
  ```
* Browser sessions fail to persist or management requests routed through an ingress receive `403` errors because Keycloak misidentifies the request origin.

## Why this happens

When the Keycloak operator renders the Quarkus distribution without an explicit proxy mode, the server assumes it is directly exposed on the public internet. In our deployment, traffic reaches Keycloak through NGINX Ingress over HTTPS and is then forwarded to the pod over plain HTTP. Without the `proxy`/`proxy-headers` options, Keycloak does not trust the `X-Forwarded-*` headers provided by the ingress controller. As a result the server believes it is running in an insecure context and warns about the missing configuration. It may also fall back to legacy hostname options and break backchannel communication with some clients.

## Fix

Update the GitOps source of truth so Keycloak honours the headers injected by the ingress controller:

1. Edit [`gitops/apps/iam/keycloak/keycloak.yaml`](../../gitops/apps/iam/keycloak/keycloak.yaml) and ensure the following `spec.proxy` configuration is present:
   ```yaml
   proxy:
     mode: edge
     headers: xforwarded
   ```
   The `edge` proxy mode tells Keycloak to expect TLS termination at the ingress boundary, while `xforwarded` enables parsing of the forwarded headers. Newer Keycloak operator releases surface these options as first-class fields; leaving them in `additionalOptions` triggers validation warnings and will be removed in a future API version.
2. Commit and push the change. Argo CD will roll the Keycloak StatefulSet to pick up the new configuration.
3. After the rollout completes, confirm the warning disappeared:

   ```bash
   kubectl logs statefulset/rws-keycloak -n iam | rg "Likely misconfiguration"
   ```
   The command should return no matches once the server restarts with the updated options.

## Additional hardening

* If you intend to expose Keycloak directly on the internet, configure TLS by setting `spec.http.tlsSecret` and disable plaintext `httpEnabled` traffic.
* Set `spec.hostname.strictBackchannel` to `true` once all clients are updated to honour the canonical hostname. This removes the `hostname-strict-backchannel` deprecation warning.
