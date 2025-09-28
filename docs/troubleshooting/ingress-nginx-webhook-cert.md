# Troubleshooting: ingress-nginx webhook certificate failures

When Argo CD applies an Ingress resource before the ingress-nginx admission webhook has a valid TLS certificate,
Kubernetes rejects the request with an error similar to:

```
one or more objects failed to apply, reason: Internal error occurred: failed calling webhook "validate.nginx.ingress.kubernetes.io": failed to call webhook: Post "https://ingress-nginx-controller-admission.ingress-nginx.svc:443/networking/v1/ingresses?timeout=10s": tls: failed to verify certificate: x509: certificate signed by unknown authority
```

This indicates that the webhook configuration does not yet contain a trusted CA bundle. The bootstrap job that ships with the
Helm chart generates a temporary CA, but it can race with the first Argo CD sync and lead to repeated reconciliation failures.

## Resolution

The GitOps configuration now delegates certificate management to cert-manager. Make sure the `platform-addons/ingress-nginx`
application has synced successfully after enabling the chart value `controller.admissionWebhooks.certManager.enabled=true`.
Cert-manager provisions a valid CA and TLS certificate for the webhook and patches the associated `ValidatingWebhookConfiguration`
so the API server can verify the TLS chain. Once the webhook is healthy, retry the failed Argo CD application sync.

If the problem persists, inspect the cert-manager events in the `ingress-nginx` namespace to confirm that the admission
certificate secret exists and that the associated Certificate resource reports `Ready`.
