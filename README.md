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
  - (Optional) `RESOURCE_PREFIX` – short lowercase prefix (1-16 chars) used in Azure resource names, default `rwsdemo`
  - `AZURE_STORAGE_KEY` – credential for the CNPG backup storage account. Supply an account key, a full connection string, or a SAS token; the bootstrap workflow normalizes it, generates a canonical connection string, and creates the Kubernetes secret CloudNativePG expects.
  - **DB secrets** (you can change later):
    - `POSTGRES_SUPERUSER_PASSWORD` – password for CNPG `postgres` (workflow stores it in a `kubernetes.io/basic-auth` secret with username `postgres`)
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
  - Creates: Resource Group, **AKS** (default Standard_B2ms node pool with one node to stay within the lightweight vCPU quotas of new subscriptions while still leaving enough memory for the demo workloads), **Storage Account** and a container for CNPG backups.
    - Override `AKS_NODE_VM_SIZE` (workflow input) or `aks_default_node_vm_size` (Terraform variable) if you have quota for a larger SKU such as `Standard_D4s_v3` and want more CPU headroom.

    - The control plane defaults to the **AKS Free** tier (`AKS_SKU_TIER` workflow input / `aks_sku_tier` Terraform variable). Leave it on `Free` to avoid uptime SLA charges and because new/free subscriptions often lack the quota required for the paid tier.
    - The default node pool upgrades with `max_surge=0` so the workflow never needs extra quota for temporary surge nodes. When surge nodes are disabled, AKS keeps `max_unavailable=1` by default to satisfy the API requirement that at least one upgrade budget is non-zero, which means upgrades briefly cordon the single system node. Expect a short outage while it is replaced; raise `aks_default_node_max_surge` once your subscription has spare vCPU capacity to keep upgrades highly available.

    - After increasing your Azure vCPU quota you can scale the cluster by overriding `AKS_NODE_COUNT` (workflow input) or `aks_default_node_count` (Terraform variable).
    - AKS upgrades that replace the system node pool (for example when switching the OS SKU) briefly request an extra node. Ensure the subscription has enough quota in the chosen VM family to accommodate that surge or request a quota increase before rerunning the workflow.
     - The workflow auto-detects whether the target resource group already exists. If it does, Terraform reuses it instead of failing. Override the name with the optional `RESOURCE_GROUP_NAME` input when you want to create or reuse a group that does not follow the default `<prefix>-rg` pattern. For local runs you can achieve the same by setting `create_resource_group=false` and `resource_group_name=<name>`.
   - The workflow now bootstraps an **Azure Storage** backend for Terraform state (resource group `<prefix>-tfstate-rg`, storage account named `${prefix}tf<subscription-hash>`, container `tfstate`). State persists across runs so replays reuse the existing AKS cluster and CNPG storage account instead of erroring when they already exist. The automation retrieves an access key for the storage account and feeds it to Terraform automatically, so you do **not** need to grant additional data-plane roles (such as *Storage Blob Data Contributor*) to the GitHub OIDC app. For local Terraform runs initialize with the same backend settings (see the workflow logs for the exact storage account name) before planning or applying.
   - Override the node pool size/count by supplying the optional workflow inputs `AKS_NODE_VM_SIZE` and `AKS_NODE_COUNT`, or by setting the corresponding Terraform variables.
   - **Heads-up**: Changing either value forces Terraform to replace the default node pool (and usually the cluster), so plan a short outage while the workflow destroys and recreates the nodes.
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
   - Run a one-off PostgreSQL job that ensures the `midpoint` database and role exist before midPoint starts
   - Enable the required PostgreSQL extensions (`pgcrypto`, `pg_trgm`) for midPoint
   - Install **Keycloak Operator** then create a **Keycloak** CR bound to CNPG
   - Deploy **midPoint** bound to CNPG
   - Create a Kubernetes **Secret** with Azure Blob credentials (from repo secrets) for CNPG backups
   - Purge any existing WAL/archive blobs in the Azure `cnpg-backups/iam-db` prefix so CloudNativePG can bootstrap cleanly on reruns

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
- Remove the Terraform state bootstrap resources if you no longer need them: `az group delete --name <prefix>-tfstate-rg`

---

## Where to change things

- **Terraform vars**: `infra/azure/terraform/terraform.tfvars` (or via repo variables / workflow inputs) – override
  `location`, `prefix`, `create_resource_group`, `resource_group_name`, `aks_default_node_vm_size`, `aks_default_node_count`, `aks_default_node_max_surge`, `aks_sku_tier` as needed.
- **Helm/Argo versions**: see `k8s/addons/*/application.yaml`
- **DB sizing**: `k8s/apps/cnpg/cluster.yaml`

- **Keycloak config**: `k8s/apps/keycloak/keycloak.yaml`
  - The `KeycloakRealmImport` inside that manifest seeds the `rws` realm. After the Keycloak Operator imports the realm it
    clears `spec.realm`, so Argo CD ignores differences on that path to avoid endless resyncs. When you change the realm
    payload, bump `metadata.annotations.iam.demo/realm-config-version` so Argo CD reapplies the manifest and Keycloak
    performs a fresh import.

- **midPoint config**: `k8s/apps/midpoint/deployment.yaml` + `k8s/apps/midpoint/config.xml`
  - The deployment constrains the JVM heap (`MP_MEM_INIT=768M`, `MP_MEM_MAX=1536M`) to keep resource usage predictable.
    Adjust these values together with the container `resources` block if you customize the AKS node sizing beyond the defaults.
  - `config.xml` uses the **native PostgreSQL repository** (Sqale) recommended for midPoint 4.9 and later, which
    matches the CloudNativePG PostgreSQL 16 cluster created by the automation.
  - An init container now copies the default `/opt/midpoint/var` contents from the image into the writable volume used for
    `midpoint.home`. This preserves the bundled keystore and directory structure so the server can start cleanly even when the
    pod is rescheduled onto a fresh node.


### Keycloak realm GitOps notes

- The Keycloak operator clears `spec.realm` on the `KeycloakRealmImport` after a successful import. Argo CD now ignores that field to prevent endless self-heal loops.
- `k8s/apps/keycloak/rws-realm.yaml` holds the desired realm. A kustomize `vars` entry injects a checksum annotation into the import so Argo CD still detects changes and re-syncs when you edit the realm file.
- `kustomize build k8s/apps` emits a deprecation warning about `vars`; this is expected for now and does not affect the rendered manifests.

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
