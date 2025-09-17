# RWS IAM Demo on AKS – Keycloak + midPoint + CloudNativePG

End-to-end demo that deploys **AKS**, **Argo CD**, **Ingress-NGINX**, **cert-manager**, **CloudNativePG (CNPG)**,
**Keycloak** and **midPoint**, then seeds midPoint with demo roles and users – all automated with **GitHub Actions (OIDC)**.

> **Low-effort path**: uses `nip.io` hostnames and self-signed/HTTP certificates for simplicity.
> You can enable Let's Encrypt later by setting DNS and the cert-manager issuer.

---

## 0) Prereqs (one-time)

- Azure subscription (Owner or Contributor on the target subscription)
- GitHub repo (this repository)
- Create a **Microsoft Entra application** and **add Federated Credentials** for this repo (GitHub OIDC).  
  Follow: GitHub → *Configuring OpenID Connect in Azure* (see links below).
- In GitHub → Settings → Secrets and variables → **Actions** → *New repository secret*:
  - `AZURE_TENANT_ID` – your Entra tenant ID
  - `AZURE_SUBSCRIPTION_ID` – your subscription ID
  - `AZURE_CLIENT_ID` – the app registration **client ID** created for OIDC
  - `ARGOCD_REPO_USERNAME` – GitHub username that owns a Personal Access Token for Argo CD
  - `ARGOCD_REPO_TOKEN` – GitHub Personal Access Token (Classic) with **repo** scope so Argo CD can clone this repo
  - (Optional) `LOCATION` – default `westeurope`
  - (Optional) `RESOURCE_PREFIX` – short prefix, default `rwsdemo`
  - **DB secrets** (you can change later):
    - `POSTGRES_SUPERUSER_PASSWORD` – password for CNPG `postgres`
    - `KEYCLOAK_DB_PASSWORD` – password for DB user `keycloak`
    - `MIDPOINT_DB_PASSWORD` – password for DB user `midpoint`
  - **midPoint admin**: `MIDPOINT_ADMIN_PASSWORD` – initial `administrator` password

> **Tip**: For the first run, keep short, simple passwords; rotate afterwards.

> **Argo CD access**: Provide the repository username/token secrets above whenever the repo is private. Without them the
> bootstrap workflow cannot register the repo with Argo CD, so it will never sync the Kubernetes applications.

---

## 1) Provision Azure & AKS with Terraform (via GitHub Actions)

1. Push this repo to GitHub.
2. Run workflow **`01_aks_apply.yml`** (Actions tab → select workflow → *Run workflow*).
   - Creates: Resource Group, **AKS** (small node size), **Storage Account** and a container for CNPG backups.
3. Once it finishes, the workflow will print outputs and mark success.

> You can stop/start AKS to save costs later: `az aks stop/start` (see links).

---

## 2) Bootstrap cluster (Argo CD, addons, DB, Keycloak, midPoint)

1. Run workflow **`02_bootstrap_argocd.yml`**.
2. The workflow will:
   - Fetch AKS kubeconfig (OIDC auth)
   - Install **Argo CD**
   - Sync **addons** via Argo: Ingress-NGINX, cert-manager, CNPG Operator
     - The workflow pre-installs CloudNativePG CRDs with `kubectl apply --server-side`. It first attempts to render them via `helm show crds` and, if the chart does not publish CRDs in that location (as happens with recent releases), falls back to `helm template --include-crds` and filters the `CustomResourceDefinition` manifests. This keeps the large schemas out of Kubernetes' annotation history while the Argo CD application disables chart-managed CRDs (`crds.create=false`) to avoid reintroducing the oversized annotation.
   - Create **CNPG** cluster `iam-db` (+ Azure Blob backup config)
   - Install **Keycloak Operator** then create a **Keycloak** CR bound to CNPG
   - Deploy **midPoint** bound to CNPG
   - Create a Kubernetes **Secret** with Azure Blob credentials (from repo secrets) for CNPG backups

> By default, services are plain HTTP for simplicity and use **`nip.io`** hostnames you can visit from your browser.

---

## 3) Seed midPoint (roles, org, minimal demo users)

1. Run workflow **`03_apply_midpoint_objects.yml`**.
2. This creates a short-lived **Kubernetes Job** that posts the XML objects in `k8s/apps/midpoint/objects/`
   into midPoint via its REST API. It uses the admin password from the GitHub secret.

---

## 4) Demo – what to click

- Get the external IP of **ingress-nginx** (the workflow prints it; or: `kubectl -n ingress-nginx get svc ingress-nginx-controller`).
- Open Keycloak: `http://kc.<EXTERNAL-IP>.nip.io` (admin user and password are in secret `rws-keycloak-initial-admin` created by operator)
- Open midPoint: `http://mp.<EXTERNAL-IP>.nip.io/midpoint`
  - Login: `administrator` / the `MIDPOINT_ADMIN_PASSWORD` you set
  - Check **Users**/**Roles**/**Orgs** seeded by the job
  - Try assigning the `Project Admin` role to a developer and observe approval in **Cases**

---

## Clean up

- Terraform destroy: run **`01_aks_apply.yml`** with `TF_ACTION: destroy` (dropdown when triggering)  
  or locally: `terraform destroy` from `infra/azure/terraform` (after `az login`).
- Or stop cluster to save money: `az aks stop --name <cluster> --resource-group <rg>`

---

## Where to change things

- **Terraform vars**: `infra/azure/terraform/terraform.tfvars` (or via repo variables / workflow inputs)
- **Helm/Argo versions**: see `k8s/addons/*/application.yaml`
- **DB sizing**: `k8s/apps/cnpg/cluster.yaml`
- **Keycloak config**: `k8s/apps/keycloak/keycloak.yaml`
  - The `KeycloakRealmImport` inside that manifest seeds the `rws` realm. After the Keycloak Operator imports the realm it
    clears `spec.realm`, so Argo CD ignores differences on that path to avoid endless resyncs. When you change the realm
    payload, bump `metadata.annotations.iam.demo/realm-config-version` so Argo CD reapplies the manifest and Keycloak
    performs a fresh import.
- **midPoint config**: `k8s/apps/midpoint/deployment.yaml` + `k8s/apps/midpoint/config.xml`

---

## References

- GitHub OIDC to Azure (`azure/login`): https://docs.github.com/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-azure
- AKS stop/start (cost saving): `az aks stop/start` – see Azure docs / blog examples
- Argo CD install manifest: https://argo-cd.readthedocs.io/en/stable/getting_started/
- Ingress-NGINX: https://kubernetes.github.io/ingress-nginx/deploy/
- cert-manager (HTTP-01): https://cert-manager.io/docs/
- CloudNativePG Azure backups (Barman): https://cloudnative-pg.io/documentation/current/backup_recovery/#backup-with-azure-blob-storage
- midPoint container config + admin password env: https://docs.evolveum.com/midpoint/reference/deployment/docker-container/
- midPoint `config.xml` (repository): https://docs.evolveum.com/midpoint/reference/deployment/midpoint-home/configuration/
- Keycloak Operator install & CRs: https://www.keycloak.org/operator/installation , https://www.keycloak.org/operator/basic-deployment , https://www.keycloak.org/operator/realm-import
