# RWS IAM Demo on AKS – GitOps Edition

This repository provisions an Azure Kubernetes Service (AKS) cluster with Terraform and then
bootstraps the platform applications entirely through GitOps:

- **Argo CD 3.x** manages reconciliation.
- **Add-on Helm charts**: cert-manager, ingress-nginx and CloudNativePG operator.
- **CloudNativePG** PostgreSQL cluster with Azure Blob backups.
- **Keycloak 26** (operator-managed) and **midPoint 4.9** bound to the same PostgreSQL database.

Everything outside of AKS provisioning lives under `gitops/` so desired state is always tracked in
Git. Automated tests validate the manifests to keep the feedback loop tight.

---

## 0) Prerequisites (one-time)

1. Azure subscription where you can create resource groups, AKS and storage accounts.
2. GitHub repository hosting this project.
3. Microsoft Entra application with Federated Credentials for GitHub OIDC.
4. Populate the following GitHub Actions repository secrets:

| Secret | Purpose |
| ------ | ------- |
| `AZURE_TENANT_ID` | Entra tenant ID used by Terraform. |
| `AZURE_SUBSCRIPTION_ID` | Subscription that will host the AKS resources. |
| `AZURE_CLIENT_ID` | Client ID of the Entra application configured for GitHub OIDC. |
| `ARGOCD_REPO_USERNAME` | GitHub username that owns a Personal Access Token so Argo CD can clone the repo. |
| `ARGOCD_REPO_TOKEN` | Personal Access Token (classic) with `repo` scope for the account above. |
| `AZURE_STORAGE_KEY` | Storage account credential (key, connection string or SAS) for CNPG backups. |
| `POSTGRES_SUPERUSER_PASSWORD` | Password for the CNPG `postgres` user. |
| `KEYCLOAK_DB_PASSWORD` | Password for the `keycloak` database role. |
| `MIDPOINT_DB_PASSWORD` | Password for the `midpoint` database role. |
| `MIDPOINT_ADMIN_PASSWORD` | Initial password for the `administrator` user in midPoint. |
| `LOCATION` *(optional)* | Azure region, defaults to `westeurope`. |
| `RESOURCE_PREFIX` *(optional)* | Lowercase prefix for Azure resources, defaults to `rwsdemo`. |

> **Tip:** start with short, simple secrets during the first bootstrap, then rotate once the demo is
> healthy.

---

## 1) Provision Azure & AKS with Terraform (GitHub Actions)

1. Push the repository to GitHub.
2. Manually run workflow **`01_aks_apply.yml`**.
   - Creates or reuses the resource group `${RESOURCE_PREFIX}-rg` (or the override you supply).
   - Deploys an AKS cluster sized for the demo workloads (defaults: `Standard_B2ms`, single node,
     Azure Linux, Free control plane tier).
   - Provisions an Azure Storage account and `cnpg-backups` container for CloudNativePG WAL/archive
     backups.
   - Configures a remote Terraform state backend in a dedicated storage account so repeated runs are
     idempotent.

You can override the node VM size or count through workflow inputs (`AKS_NODE_VM_SIZE`,
`AKS_NODE_COUNT`). Expect a node pool replacement if you change these values after the initial run.

---

## 2) Bootstrap Argo CD and the platform (GitOps-native)

All cluster add-ons and applications are reconciled by Argo CD. The only imperative step is the
initial Argo CD installation, handled by a tiny helper script:

```bash
# From your workstation once kubeconfig points at the new AKS cluster
pip install -r requirements-dev.txt    # installs pytest/pyyaml for local validation (optional)
./scripts/bootstrap.sh                 # installs Argo CD v3.1.7 and registers the GitOps tree
```

The script applies the upstream Argo CD install manifest and then applies `gitops/argocd`, which
contains the two Application definitions:

- `addons` → syncs Helm charts through an ApplicationSet (cert-manager v1.18.2, CNPG 0.26.0,
  ingress-nginx 4.13.2).
- `platform` → renders the declarative manifests for CNPG, Keycloak and midPoint.

Argo CD performs automated sync, pruning and self-healing, so every subsequent change only requires a
pull request that edits the manifests or values inside `gitops/`.

---

## 3) Rotate ingress hosts for the demo endpoints

Argo CD treats the ingress hosts and class as configuration data. Update the Git-managed parameters
with the helper script once the ingress controller publishes an external IP:

```bash
./scripts/configure_demo_hosts.sh
```

The script waits for the ingress controller rollout, resolves the load balancer IP/hostname, writes
`gitops/apps/platform/params.env` and prints the resulting Keycloak (`http://kc.<IP>.nip.io`) and
midPoint (`http://mp.<IP>.nip.io/midpoint`) URLs. Commit and push the updated file so Argo CD
reconciles the new hosts.

---

## GitOps layout

```
gitops/
├── argocd/           # Argo CD Applications that register the add-ons and platform trees
├── apps/
│   ├── addons/       # ApplicationSet + Keycloak operator bootstrap
│   └── platform/     # CNPG cluster, Keycloak, realm import, midPoint
└── ...
```

Key files:

| Component | Path |
| --------- | ---- |
| CNPG cluster & backup policy | `gitops/apps/platform/cnpg/cluster.yaml` |
| CNPG backup settings | `gitops/apps/platform/cnpg/params.env` (update `storageAccount`) |
| Keycloak deployment | `gitops/apps/platform/keycloak/keycloak.yaml` |
| Keycloak realm | `gitops/apps/platform/keycloak/rws-realm.yaml` |
| midPoint deployment | `gitops/apps/platform/midpoint/deployment.yaml` |
| Ingress hosts/classes | `gitops/apps/platform/params.env` |

The repository keeps strongly typed configuration inside the CRDs rather than `additionalOptions`
or ad-hoc patches. GitOps controllers reconcile everything through Server-Side Apply, ensuring
idempotence and easy diffing.

---

## Testing & validation

The project is test-driven: every pull request should pass the manifest validation suite.

```bash
pip install -r requirements-dev.txt
make test
```

The pytest suite covers:

- Argo CD Applications pin `targetRevision=main` and auto-create namespaces.
- Helm charts in the ApplicationSet are version pinned and use HTTPS repositories.
- Keycloak manifests avoid deprecated CLI flags and rely on typed database fields.
- `scripts/bootstrap.sh` pins the Argo CD version and applies the GitOps tree.

Add new tests whenever you introduce manifests or automation. Treat `make test` as the pre-commit
contract before opening a PR.

---

## Operations quick reference

- **Update Keycloak or midPoint**: edit the manifests under `gitops/apps/platform/keycloak` or
  `gitops/apps/platform/midpoint` and bump image tags. `make test` will verify you did not reintroduce
  legacy flags.
- **Adjust PostgreSQL sizing**: edit `gitops/apps/platform/cnpg/cluster.yaml`.
- **Azure Blob backup target**: update `storageAccount` in
  `gitops/apps/platform/cnpg/params.env` to match the Terraform output.
- **Argo CD upgrade**: bump the default version in `scripts/bootstrap.sh` and update the
  ApplicationSet chart versions. The tests will fail if the version string is missing.

---

## References

- GitHub OIDC to Azure (`azure/login`): <https://docs.github.com/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-azure>
- CloudNativePG backups on Azure Blob: <https://cloudnative-pg.io/documentation/current/backup_recovery/#backup-with-azure-blob-storage>
- Keycloak operator: <https://www.keycloak.org/operator/basic-deployment>
- midPoint container deployment: <https://docs.evolveum.com/midpoint/reference/deployment/docker-container/>
- Ingress-NGINX on AKS: <https://kubernetes.github.io/ingress-nginx/deploy/>
