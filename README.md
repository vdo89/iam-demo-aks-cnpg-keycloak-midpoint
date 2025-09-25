# RWS IAM Demo on AKS – GitOps Edition

This repository provisions an Azure Kubernetes Service (AKS) cluster with Terraform, then lets Argo CD reconcile everything else: CloudNativePG (CNPG), Keycloak, midPoint and the supporting ingress/PKI stack.  All cluster state is declared in Git – overlays capture environment-specific values and tests guard the conventions that keep the repo convergent.

---

## Repository map

```
├── infra/azure/terraform        # AKS + Azure storage for CNPG backups
├── gitops
│   ├── bootstrap/               # Minimal Argo CD install + ApplicationSet bootstrap
│   ├── addons/                  # Helm-based addons (cert-manager, ingress-nginx, CNPG operator, Keycloak operator)
│   └── iam/                     # CloudNativePG cluster, Keycloak, midPoint (base + overlays)
├── clusters/                    # Argo CD Applications per cluster (demo is the reference overlay)
├── requirements-dev.txt         # Python tooling for the lightweight tests
└── tests/                       # pytest assertions that keep manifests strongly typed & pinned
```

---

## Prerequisites (one time)

1. **Azure** subscription with rights to create resource groups, AKS and storage.
2. **GitHub OIDC** application (client ID, tenant ID, subscription ID) wired to this repository so CI can run Terraform.
3. Repository secrets (GitHub → Settings → Secrets and variables → Actions):
   - `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_ID`
   - `AZURE_STORAGE_KEY` – account key, connection string or SAS for the CNPG backup storage
   - `POSTGRES_SUPERUSER_PASSWORD`, `KEYCLOAK_DB_PASSWORD`, `MIDPOINT_DB_PASSWORD`
   - `MIDPOINT_ADMIN_PASSWORD`
   - (Private repos only) `ARGOCD_REPO_USERNAME`, `ARGOCD_REPO_TOKEN`
4. Python 3.11+ locally if you want to run the tests (`pip install -r requirements-dev.txt`).

---

## Step 1 – Provision AKS with Terraform

The Terraform module under `infra/azure/terraform` stayed intact but leans on newer defaults (Azure Linux nodes, CNPG-ready storage). Run it either via the supplied GitHub Action (`01_aks_apply.yml`) or locally:

```bash
cd infra/azure/terraform
terraform init
terraform apply \
  -var 'prefix=rwsdemo' \
  -var 'location=westeurope'
```

Outputs:
- AKS cluster `<prefix>-aks`
- Storage account for CNPG backups (`<prefix>sa<random>`)

The Terraform state is remote-backend ready; reuse the storage account created by the first run if you execute subsequent plans locally.

---

## Step 2 – Declare cluster-specific values in Git

Everything after Terraform is pure GitOps. Update these files **before** bootstrapping Argo CD and commit the changes so operators can track them:

| File | Purpose |
| --- | --- |
| `gitops/iam/overlays/demo/params.env` | Ingress class, Keycloak & midPoint hosts (nip.io or your real domain), CNPG storage account name |
| `clusters/demo/kustomization.yaml` | Repository URL + branch/tag Argo CD should watch |
| `gitops/bootstrap/overlays/demo/kustomization.yaml` | Same repo metadata for the bootstrap ApplicationSet |

The overlays ship with obvious placeholders (`https://github.com/your-org/...`, `kc.0.0.0.0.nip.io`, `rwsdemocnpgsa`). Replace them with values that match your environment and push the commit.

---

## Step 3 – Bootstrap Argo CD (once per cluster)

1. Fetch kubeconfig for the AKS cluster (OIDC with `az login` or via GitHub Actions job).
2. Apply the bootstrap overlay – it vendors the pinned Argo CD install manifest straight from upstream and wires the ApplicationSet that tracks `clusters/*`:

   ```bash
   kubectl apply -k gitops/bootstrap/overlays/demo
   ```

3. Wait for the bootstrap ApplicationSet to create the `demo` root Application. The root, in turn, submits two Applications (`demo-addons` and `demo-iam`).
4. Follow their progress either with `argocd app list --core` or `kubectl get applications.argoproj.io -n argocd` until they report `Healthy/Synced`.

Because repo URLs live in the overlays, promoting changes to staging/prod is as simple as copying the overlay and adjusting the values.

---

## Step 4 – Explore the stack

Once Argo CD reports `Healthy`:

- **Ingress controller IP**: `kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
- **Keycloak**: `http://<keycloakHost from params.env>/` – initial admin credentials live in secret `rws-keycloak-initial-admin`.
- **midPoint**: `http://<midpointHost>/midpoint` – log in with `administrator` / `MIDPOINT_ADMIN_PASSWORD`.
- **Database**: CloudNativePG exposes the primary through service `iam-db-rw.iam.svc.cluster.local` with TLS by default.

The Git-managed seeder job keeps midPoint objects convergent; re-syncing the `demo-iam` application reapplies the XML definitions safely.

---

## Tests & validation

A tiny pytest suite protects the GitOps contract:

```bash
pip install -r requirements-dev.txt
pytest
```

The tests assert that:
- The Keycloak CR only uses strongly typed fields (no legacy CLI overrides).
- Overlays override the default ingress hosts & CNPG storage account placeholder.
- Cluster Applications reference the new `gitops/...` layout and use kustomize vars.
- Addon chart versions stay pinned to known-good releases.

Run the suite before pushing changes – it’s fast and guards against accidental drift.

---

## Clean up

Destroy the Azure resources when you are done:

```bash
cd infra/azure/terraform
terraform destroy
```

Or stop the AKS cluster temporarily with `az aks stop --name <cluster> --resource-group <rg>` to save costs.

---

## Need to customise more?

- Add another cluster by copying `clusters/demo` to `clusters/<env>` and creating a matching overlay under `gitops/iam/overlays/<env>`.
- Extend addons by editing `gitops/addons/base/applicationset.yaml` (tests enforce pinned versions).
- Keep secrets outside Git. The manifests expect Kubernetes secrets named `cnpg-azure-backup`, `keycloak-db-app`, `midpoint-db-app`, and `midpoint-admin` – the bootstrap workflow or your secret management solution should populate them.

Everything above is declarative; once the overlays match your Azure environment, Argo CD will reconcile the cluster to the desired state without additional scripts or ad-hoc kubectl invocations.
