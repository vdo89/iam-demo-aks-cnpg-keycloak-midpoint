# AKS GitOps demo: Keycloak + midPoint on CloudNativePG

This repository provisions an Azure Kubernetes Service (AKS) cluster, installs
Argo CD, and reconciles a GitOps tree that deploys CloudNativePG, Keycloak and
midPoint. The bootstrap is intentionally small: once AKS exists, the only
imperative action is running `scripts/bootstrap.sh` (or the GitHub workflow that
wraps it). Everything else is declarative YAML or Terraform.

## What's new in this refactor?

* **GitOps-first layout** – Kubernetes manifests live under `clusters/aks` with a
  single kustomization driving all Argo CD applications.
* **Static ingress IP** – Terraform now allocates a dedicated public IP for the
  ingress controller. The GitOps manifests reference it, so Keycloak and
  midPoint always reconcile to known hostnames.
* **Condensed tooling** – The bootstrap shell script applies the pinned Argo CD
  manifest and the root kustomization. A tiny Python helper (`scripts/render_hosts.py`)
  renders the nip.io hosts and is covered by unit tests.
* **Continuous validation** – `pytest` tests validate the helper scripts. The
  `00 - Validate GitOps assets` workflow runs them on each push and PR.

## Prerequisites

* Azure subscription with permissions to create resource groups, AKS and
  storage accounts.
* GitHub repository that hosts this code.
* GitHub Actions secrets:
  * `AZURE_TENANT_ID`
  * `AZURE_SUBSCRIPTION_ID`
  * `AZURE_CLIENT_ID` (OIDC app registration)
  * `ARGOCD_REPO_USERNAME` / `ARGOCD_REPO_TOKEN` if the repo is private.
* Optional: Python 3.11+ locally for the helper script and tests.

## Step 1 – Provision AKS with Terraform

Trigger the **`01 - Provision AKS`** workflow. Choose `apply` (or `destroy`). The
workflow:

1. Ensures a remote state storage account `${prefix}tfstate` in resource group
   `${prefix}-tfstate`.
2. Runs `terraform apply` inside `infra/azure/terraform`, creating:
   * Resource group (`<prefix>-rg`)
   * AKS cluster
   * Storage account + container for CloudNativePG backups
   * Static public IP for the ingress controller

Capture the outputs (`terraform output`) if you run Terraform locally; the
GitHub workflow prints them in the logs.

## Step 2 – Bootstrap GitOps

Run **`02 - Bootstrap GitOps stack`** and provide the resource group and cluster
name from Terraform outputs. The workflow:

1. Logs into Azure and fetches the kubeconfig.
2. Runs `scripts/bootstrap.sh` to install Argo CD `v2.11.3` and apply the root
   kustomization under `clusters/aks/argocd`.
3. Executes `python scripts/render_hosts.py --kubectl --update-values` to rewrite
   `clusters/aks/apps/params.env` and patch
   `clusters/aks/addons/ingress-nginx.values.yaml` with the resolved ingress IP
   and resource group. The resulting commit lands back in the repo via
   `stefanzweifel/git-auto-commit-action`.

Once the workflow finishes, Argo CD reconciles the `addons` and `apps`
applications automatically. Keycloak and midPoint should converge a few minutes
later.

## Managing ingress hosts

The `clusters/aks/addons/ingress-nginx.values.yaml` file pins the static public IP
assigned by Terraform. After the first `terraform apply`, update the file by
running:

```bash
python scripts/render_hosts.py \
  --ip "$(terraform -chdir=infra/azure/terraform output -raw ingress_public_ip)" \
  --resource-group "$(terraform -chdir=infra/azure/terraform output -raw resource_group)" \
  --update-values
```

Commit the change so Argo CD restarts the ingress controller with the correct IP
and regenerates the nip.io hosts.

## Local developer workflow

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
make test
```

`make bootstrap` requires a valid kubeconfig pointing at the AKS cluster and
will apply the same manifests as the GitHub workflow.

## Repository layout

```
clusters/aks/
  argocd/        # Root Argo CD objects (namespace, projects, applications)
  addons/        # Helm-driven addons (cert-manager, ingress-nginx, CNPG)
  apps/          # Application workloads: CloudNativePG cluster, Keycloak, midPoint
infra/azure/     # Terraform that provisions AKS + dependencies
scripts/         # Bootstrap + helper utilities
tests/           # Pytest suite for helper scripts
```

## Tests

Unit tests cover the Python helper and run in CI. Extend the suite whenever you
add new automation—keeping everything testable keeps the bootstrap tiny and
predictable.
