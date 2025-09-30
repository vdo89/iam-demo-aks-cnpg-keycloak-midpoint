# Argo CD ingress returns 502 Bad Gateway

## Symptoms
- The Argo CD UI served via the ingress immediately fails with `502 Bad Gateway`.
- `kubectl -n argocd logs deploy/ingress-nginx-controller` shows upstream TLS handshake errors such as `remote error: tls: bad certificate`.

## Root cause
The bootstrap overlay now forces the Argo CD server to run in insecure (HTTP) mode so that browsers will accept the session cookie over HTTP. The ingress was still annotated to talk to the backend over HTTPS, so NGINX tried to establish a TLS connection to the plain-HTTP server pod and failed, resulting in a 502 response.

## Fix
1. Update the ingress annotation so the controller uses HTTP when proxying to `argocd-server`:
   ```sh
   kubectl -n argocd annotate ingress argocd-server \
     nginx.ingress.kubernetes.io/backend-protocol="HTTP" --overwrite
   ```
2. Wait for the ingress controller to reload (`kubectl -n ingress-nginx logs deploy/ingress-nginx-controller -f`).
3. Refresh the Argo CD endpoint. It should now load successfully.

## Long-term remediation
This repository now sets `nginx.ingress.kubernetes.io/backend-protocol: "HTTP"` in `gitops/clusters/aks/bootstrap/argocd-ingress.yaml`. Re-run the **“02 - Bootstrap Argo CD”** workflow (or `kubectl apply -k gitops/clusters/aks/bootstrap`) so existing clusters pick up the change.
