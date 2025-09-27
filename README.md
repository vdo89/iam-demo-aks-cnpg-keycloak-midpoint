# RWS IAM Demo on AKS – GitOps edition

This repository provisions an Azure Kubernetes Service (AKS) cluster with Terraform and then bootstraps a complete IAM demo stack – CloudNativePG, Keycloak and midPoint – using Argo CD. Everything beyond the AKS control plane is declarative: manifests live in Git, Argo CD reconciles them, and helper scripts simply keep the Git-managed parameters up to date.

## Repository layout

```
infra/azure/terraform/   # Minimal Terraform to stand up AKS + storage for CNPG backups
gitops/                  # Argo CD projects, applications and workload manifests
scripts/                 # Helper utilities (ingress host discovery, secret normalisation)
.github/workflows/       # Terraform apply/destroy, GitOps bootstrap and ingress automation
requirements-dev.txt     # Python tooling for unit tests and scripts
```

## 0. Prerequisites

1. **Azure subscription** with permission to create resource groups, AKS clusters and storage accounts.
2. **GitHub repository** containing this project.
3. **Azure AD application** configured for GitHub OIDC. Add the following secrets to your repository (Settings → Secrets and variables → Actions):
   - `AZURE_TENANT_ID`
   - `AZURE_SUBSCRIPTION_ID`
   - `AZURE_CLIENT_ID`
   - `AZURE_STORAGE_KEY` – storage account key, SAS token or connection string used for CNPG backups
   - `POSTGRES_SUPERUSER_PASSWORD`
   - `KEYCLOAK_DB_PASSWORD`
   - `MIDPOINT_DB_PASSWORD`
   - `MIDPOINT_ADMIN_PASSWORD`
   - *(optional, only for private repositories)* `ARGOCD_REPO_USERNAME` and `ARGOCD_REPO_TOKEN`
4. Update the GitOps configuration:
   - Set `data.repoURL` (and optionally `data.targetRevision`) in [`gitops/clusters/aks/context.yaml`](gitops/clusters/aks/context.yaml) to point at **your** repository.
   - Provide the CloudNativePG backup storage account to the bootstrap workflow via its `STORAGE_ACCOUNT` input (the workflow now writes [`gitops/apps/iam/cnpg/params.env`](gitops/apps/iam/cnpg/params.env) for you).

## 1. Provision AKS with Terraform

Trigger the workflow **“01 - Provision AKS with Terraform”** (`.github/workflows/01_aks_apply.yml`). The pipeline initialises an Azure Storage backend for Terraform state, provisions the resource group, storage account and AKS cluster, and exposes the relevant outputs.

> To destroy the infrastructure, rerun the workflow with the `TF_ACTION` input set to `destroy`.

## 2. Bootstrap Argo CD and the demo stack

1. Run the workflow **“02 - Bootstrap GitOps stack”** (`.github/workflows/02_bootstrap_argocd.yml`). Provide the `STORAGE_ACCOUNT` input so the job can render the CNPG backup configuration. It will:
   - Apply the Argo CD bootstrap kustomization pinned to `v3.1.7`.
   - Optionally configure repository credentials when the repo is private.
   - Validate the GitOps manifests via the unit tests before touching the cluster.
   - Create the database and admin secrets in the `iam` namespace.
   - Configure Keycloak with an explicit JDBC URL that enforces TLS (`?sslmode=require`) when connecting to the CloudNativePG pri
     mary so the readiness health check succeeds even when the database enforces encrypted connections.
   - Normalise the Azure Blob credentials into the `cnpg-azure-backup` secret using `scripts/normalize_azure_storage_secret.py`.
   - Apply the GitOps tree (`gitops/clusters/aks`) so Argo CD manages addons (cert-manager, CloudNativePG operator, ingress-nginx, Keycloak operator) and the IAM workloads (CloudNativePG cluster, Keycloak, midPoint).
   - Wait for all applications to report `Synced` and `Healthy`.
   - Wait for the Keycloak operator CRDs (`keycloaks.k8s.keycloak.org`, `keycloakrealmimports.k8s.keycloak.org`) to appear; the workflow now deploys the upstream manifests automatically and surfaces detailed diagnostics if the CRDs never register.

### Troubleshooting: Argo CD project denies the repo

If the `iam` application reports `application repo … is not permitted in project 'iam'`, make sure the AppProject allows the exact Git repository URL. The default configuration now whitelists both the templated `$(GITOPS_REPO_URL)` value used by the bootstrap workflow and the canonical `https://github.com/vdo89/iam-demo-aks-cnpg-keycloak-midpoint` remote so freshly bootstrapped clusters reconcile immediately. Adjust [`gitops/clusters/aks/projects/iam.yaml`](gitops/clusters/aks/projects/iam.yaml) if you fork the project or host the manifests elsewhere.

### Troubleshooting: Secrets stuck on `type` immutability

Argo CD 2.11 migrates existing resources to client-side apply, which surfaces immutable field errors if the live object was created with a different schema than the GitOps source. The bootstrap workflow now seeds the IAM database and admin credentials as [`Opaque` secrets](.github/workflows/02_bootstrap_argocd.yml) and proactively deletes any older basic-auth secrets before recreating them. If the application remains `Degraded` with a message similar to `Secret "keycloak-db-app" is invalid: type: Invalid value: "kubernetes.io/basic-auth": field is immutable`, delete the affected secret (Argo will recreate it on the next sync) so the type converges on the new schema.

### Troubleshooting: Keycloak health never reaches ready

If Argo CD stalls on `waiting for healthy state of k8s.keycloak.org/Keycloak/rws-keycloak`, the Keycloak readiness endpoint is
reporting `DOWN`. Follow the runbook in
[`docs/troubleshooting/keycloak-health-degraded.md`](docs/troubleshooting/keycloak-health-degraded.md) to capture the relevant
controller logs, inspect the `/health/ready` payload and resolve the underlying database or configuration error.

### Troubleshooting: IAM sync timeout waiting for Keycloak CRDs

When the IAM application reports `one or more synchronization tasks are not valid due to application controller sync timeout`, Argo CD is trying to apply Keycloak custom resources before the operator finishes installing its CRDs. Longer timeouts do not help because the resources remain invalid until the CRDs appear. Follow the runbook in [`docs/troubleshooting/iam-sync-timeout.md`](docs/troubleshooting/iam-sync-timeout.md) to gather the relevant controller state and apply the sync-wave fix so the Keycloak operator finishes before the IAM stack reconciles.

## 3. Publish demo ingress hostnames

Run the workflow **“04 - Configure demo hosts”** after the bootstrap finishes. The job calls [`scripts/configure_demo_hosts.py`](scripts/configure_demo_hosts.py) to discover the ingress IP, updates [`gitops/apps/iam/params.env`](gitops/apps/iam/params.env) with fresh `nip.io` hostnames, commits the change and prints the URLs. Argo CD is exposed through an HTTP ingress (TLS terminates at the `argocd-server` service), so the generated Argo link intentionally uses `http://`.

## 4. Day-two tips

- The GitOps tree lives under `gitops/`. Update manifests, commit, and let Argo CD reconcile the cluster. `kubectl apply` is only needed for the initial bootstrap.
=======
- Keycloak starts without the optimized flag on first boot (`startOptimized: false`) so that the stock container image performs its initial build step successfully. After the first run you can bake a pre-built image and re-enable the optimized path for faster restarts.


- Need to rotate ingress hosts manually? Execute `python3 scripts/configure_demo_hosts.py --ingress-ip <EXTERNAL-IP>` and commit the updated parameters file.

### Debugging Argo CD repo permissions

If the IAM application loops with `application repo ... is not permitted in project 'iam'`, ensure the kustomization rendered the `gitops/clusters/aks/projects/iam.yaml` manifest with your repository URL. The AppProject’s `spec.sourceRepos` is templated via `kustomizeconfig/argocd-applications.yaml`; reapply the bootstrap kustomization after updating [`context.yaml`](gitops/clusters/aks/context.yaml) so the ConfigMap and AppProject stay in sync.

## 5. Testing locally

Install the lightweight toolchain and run the unit tests:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
pytest
```

The tests cover the helper scripts and sanity-check the GitOps manifests (chart versions, application placeholders, etc.).

## 6. Clean up

- **Terraform destroy**: rerun the provisioning workflow with `TF_ACTION=destroy` or execute `terraform destroy` from `infra/azure/terraform` after running `terraform init` with the same backend settings as the pipeline.
- **Pause the cluster**: `az aks stop --name <cluster> --resource-group <rg>` reduces costs without deleting anything.
