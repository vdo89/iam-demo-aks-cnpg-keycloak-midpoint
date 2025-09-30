# Argo CD admin login loops back to the sign-in page

## Symptoms
- Signing in to the Argo CD UI with the `admin` username and the password from `argocd-initial-admin-secret` briefly flashes the loading spinner and immediately returns to the login screen.
- Browser developer tools show that the `argocd.token` cookie is never persisted when you authenticate through `http://`.

## Root cause
The upstream Argo CD manifest enables TLS on the `argocd-server` pod and sets the `Secure` attribute on the session cookie. Our ingress presents Argo CD over plain HTTP (TLS terminates at the Kubernetes service), so browsers drop the secure cookie and you are bounced back to the login page.

## Fix
1. Patch the `argocd-cmd-params-cm` ConfigMap so the server runs in insecure mode and stops marking the cookie as `Secure`:
   ```sh
   kubectl -n argocd patch configmap argocd-cmd-params-cm \
     --type merge \
     -p '{"data":{"server.insecure":"true"}}'
   kubectl -n argocd rollout restart deploy argocd-server
   ```
2. Wait for the rollout to complete (`kubectl -n argocd get pods`).
3. Refresh the Argo CD UI and sign in again with the same credentials. The login now sticks because the cookie can be stored over HTTP.

## Long-term remediation
This repository now includes the patch in `gitops/clusters/aks/bootstrap/argocd-cmd-params-cm-patch.yaml`. Re-run the **“02 - Bootstrap Argo CD”** workflow (or `kubectl apply -k gitops/clusters/aks/bootstrap`) so future clusters automatically set `server.insecure: "true"` during bootstrap.
