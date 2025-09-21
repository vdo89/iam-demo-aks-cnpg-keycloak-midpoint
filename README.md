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
    - The default node pool accepts `max_surge=0` as input so the workflow avoids requesting temporary surge nodes on constrained subscriptions. Because the current AzureRM provider cannot set `max_unavailable`, the Terraform module now coerces that value to Azure's default of `max_surge=1` so the cluster keeps a valid upgrade budget. Expect a short outage while the single system node is replaced; raise `aks_default_node_max_surge` once your subscription has spare vCPU capacity to keep upgrades highly available.

    - After increasing your Azure vCPU quota you can scale the cluster by overriding `AKS_NODE_COUNT` (workflow input) or `aks_default_node_count` (Terraform variable).
    - AKS upgrades that replace the system node pool (for example when switching the OS SKU) briefly request an extra node. Ensure the subscription has enough quota in the chosen VM family to accommodate that surge or request a quota increase before rerunning the workflow.
     - The workflow auto-detects whether the target resource group already exists. If it does, Terraform reuses it instead of failing. Override the name with the optional `RESOURCE_GROUP_NAME` input when you want to create or reuse a group that does not follow the default `<prefix>-rg` pattern. For local runs you can achieve the same by setting `create_resource_group=false` and `resource_group_name=<name>`.
   - The workflow now bootstraps an **Azure Storage** backend for Terraform state (resource group `<prefix>-tfstate-rg`, storage account named `${prefix}tf<subscription-hash>`, container `tfstate`). State persists across runs so replays reuse the existing AKS cluster and CNPG storage account instead of erroring when they already exist. The automation retrieves an access key for the storage account and feeds it to Terraform automatically, so you do **not** need to grant additional data-plane roles (such as *Storage Blob Data Contributor*) to the GitHub OIDC app. For local Terraform runs initialize with the same backend settings (see the workflow logs for the exact storage account name) before planning or applying.
   - Terraform commands in the workflow run through a wrapper that now auto-unlocks stale state locks: it forces an unlock when a lock is older than one hour or when the same lock blocks three retries in a row. Override the thresholds with the environment variables `TERRAFORM_LOCK_FORCE_UNLOCK_AFTER_SECONDS` and `TERRAFORM_LOCK_FORCE_UNLOCK_AFTER_ATTEMPTS` (set either to `0` to disable the corresponding guard) if you need a different policy for local runs.
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
   - Run one-off PostgreSQL jobs that ensure the `keycloak` and `midpoint` databases and roles exist before the apps start. The helpers also reset the role passwords so reruns pick up new GitHub secret values.
   - Enable the required PostgreSQL extensions (`pgcrypto`, `pg_trgm`) for midPoint
   - Install **Keycloak Operator** then create a **Keycloak** CR bound to CNPG
     - The workflow now reconfigures the operator deployment to watch the `iam` application namespace (in addition to its home namespace) so it publishes the generated services, such as `rws-keycloak-service`, where Argo CD manages the workloads.
   - Deploy **midPoint** bound to CNPG
   - Create a Kubernetes **Secret** with Azure Blob credentials (from repo secrets) for CNPG backups
   - Purge any existing WAL/archive blobs in the Azure `cnpg-backups/iam-db` prefix so CloudNativePG can bootstrap cleanly on reruns
   - When Argo CD leaves the `apps` application in `Progressing` because certain custom resources never publish health status (for example, the Keycloak CRDs), the workflow logs the affected objects once and continues after confirming no other workloads are still reconciling. This prevents a timeout even though the pods are already running.

> By default, services are plain HTTP for simplicity and use **`nip.io`** hostnames you can visit from your browser.

---

## 3) Seed midPoint (roles, org, minimal demo users)

1. Run workflow **`03_apply_midpoint_objects.yml`**.
2. This creates a short-lived **Kubernetes Job** that posts the XML objects in `k8s/apps/midpoint/objects/`
   into midPoint via its REST API. It uses the admin password from the GitHub secret.

---

## 4) Publish demo ingress hostnames

1. Run workflow **`04_configure_demo_hosts.yml`**.
2. The helper script (`scripts/configure_demo_hosts.sh`) discovers the `ingress-nginx` load balancer address,
   waits for the Keycloak and midPoint services to expose ready pods, updates the GitOps ingress host patches
   (`k8s/apps/keycloak/ingress-host-patch.yaml` and `k8s/apps/midpoint/ingress-host-patch.yaml`) with
   `kc.<IP>.nip.io` and `mp.<IP>.nip.io`, applies them once so you can browse immediately, and lets the workflow
   commit the patch files back to the repo. Argo CD now reconciles the dynamic hosts directly from Git instead
   of relying on `ignoreDifferences` rules.

---

## 5) Demo – what to click

- Get the external IP of **ingress-nginx** (the workflow prints it; or: `kubectl -n ingress-nginx get svc ingress-nginx-controller`).
- Keycloak is exposed through the operator-managed service `rws-keycloak-service`; check it with `kubectl -n iam get svc rws-keycloak-service` if you need the cluster IP before Ingress is ready.
- Open Keycloak: `http://kc.<EXTERNAL-IP>.nip.io/auth` (admin user and password are in secret `rws-keycloak-initial-admin` created by operator)
  - The deployment restores Keycloak's legacy `/auth` base path so older clients, including midPoint's built-in Keycloak integration, reach the realm endpoints without 404s.
  - The Keycloak Operator exposes HTTP on service **`rws-keycloak-service`** (note the `-service` suffix). Use `kubectl -n iam get svc` to list the generated service names instead of querying `rws-keycloak` directly.
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
  - `startOptimized` is explicitly disabled so the container re-runs `kc.sh build` with the database and health check
    settings every time the pod starts. Keycloak 26 exits early with `The following build time options have values that
    differ...` when the optimized image still carries the default `kc.db=dev-file`/`kc.health-enabled=false` values from
    the upstream image, so letting the runtime build step execute avoids the crash loop without having to maintain a
    pre-built custom image.
  - Keycloak enables the CLI flag `health-enabled=true` so the readiness endpoints are exposed for the operator's probes.
    Keycloak 26.0.8 removed the legacy `health` feature toggle, so the manifest now wires the option through
    `spec.additionalOptions` instead of relying on environment variables or the operator's default feature set.
    Leaving the old flag in place makes the container exit with `health is an unrecognized feature`, which surfaces as
    a CrashLoopBackOff in Argo CD. The current Keycloak Operator release still injects `health` whenever the feature list
    is empty, so the manifest pins `spec.features.enabled` and the explicit `features` additional option to a harmless
    entry (`token-exchange`) to force the operator to stop requesting the removed flag. Setting `spec.features.disabled`
    to `health` still makes the operator render the removed toggle, so the disabled list stays empty and the manifest
    relies solely on the explicit enabled entry. If you upgrade the image again and the health endpoints disappear,
    review the upstream release notes for the replacement configuration knob before adjusting the feature list.

  - The manifest pins Keycloak to **26.0.8** because 26.0.0 fails to start once build-time options such as `kc.db`
    or `kc.health-enabled` diverge from what was baked into the optimized image, which is exactly the case for this
    deployment. The regression was fixed upstream (Keycloak issue #33902) and shipping the patched image ensures the
    StatefulSet does not get stuck in a CrashLoopBackOff when we reconcile the database and health settings.
    Keycloak 26 automatically rebuilds the optimized image when runtime options change, and the legacy `auto-build`
    configuration knob was removed upstream. Leaving the old `kc.auto-build=true` entry forces the operator to render the
    invalid `--kc.auto-build` flag which causes the pod to exit immediately, so the manifest purposely omits that option.
  - The PostgreSQL connection now uses an explicit JDBC URL with `sslmode=disable` so Keycloak skips TLS validation against
    CloudNativePG's self-signed server certificate. The value is expressed both in the CRD's database section and via
    `spec.additionalOptions` to guarantee the exact JDBC string (including the query parameters) always reaches the
    container even if the operator rewrites the database options. Without this override the startup probe repeatedly fails
    with `connection refused`, the pod restarts, and the application never reaches Healthy.

- **midPoint config**: `k8s/apps/midpoint/deployment.yaml` + `k8s/apps/midpoint/config.xml`
  - The deployment constrains the JVM heap (`MP_MEM_INIT=768M`, `MP_MEM_MAX=1536M`) to keep resource usage predictable.
    Adjust these values together with the container `resources` block if you customize the AKS node sizing beyond the defaults.
  - `config.xml` uses the **native PostgreSQL repository** (Sqale) recommended for midPoint 4.9 and later, which
    matches the CloudNativePG PostgreSQL 16 cluster created by the automation.
    The JDBC URL explicitly sets `sslmode=disable` because CloudNativePG issues self-signed server certificates by default and
    the demo deployment does not distribute a CA bundle to midPoint. Without the flag the driver may abort during the TLS
    handshake and the pod will restart in a crash loop. Disable the flag only after you install a trusted server certificate
    and update the midPoint keystore accordingly.
    The deployment now clears the container image's default `MP_SET_midpoint_repository_*` environment variables (including
    the JDBC URL and credentials) so the rendered `config.xml` remains authoritative for repository settings instead of
    reverting to the bundled H2 defaults or the sample `midpoint/midpoint` password.
  - The `midpoint-db-init` container renders `config.xml` from a template using the database credentials mounted as files.
    This keeps the GitOps manifests credential-free while ensuring the running pod always picks up the latest JDBC settings.
    Update both the manifest (for the JDBC URL or secret paths) and the GitHub secrets when changing the database hostname,
    username or password. The helper now also escapes XML entities so passwords containing characters such as `&` or `<`
    no longer corrupt the rendered configuration.
  - An init container now runs `midpoint.sh init-native` and then drives `ninja.sh run-sql` to create **and upgrade** the
    PostgreSQL schema before the main pod starts. The workflow is idempotent, so it safely bootstraps fresh clusters and also
    applies in-place upgrades when you bump the midPoint image version. The helper retries `midpoint.sh` and every `ninja`
    invocation with exponential backoff, masking credentials in the captured logs so transient database hiccups do not leave
    the pod stuck in a crash loop and operators have actionable diagnostics when a retry finally gives up.
  - An init container now copies the default `/opt/midpoint/var` contents from the image into the writable volume used for
    `midpoint.home`. This preserves the bundled keystore and directory structure so the server can start cleanly even when the
    pod is rescheduled onto a fresh node.
  - Secrets are mounted as files so the init script can read the literal credential values without exposing them to shell
    expansion. Without this, the `midpoint-db-init` init container kept crashing during the `ninja` schema commands because Bash
    expanded characters such as `$$` to the process ID, causing authentication failures. The updated helper reads the
    credentials directly from the mounted files, substitutes them into `config.xml`, and invokes `ninja` with enhanced error
    logging so failed runs surface the sanitized command output instead of leaving operators to guess at the root cause.

### Troubleshooting: midPoint init container crash loops

- **Symptom**: Argo CD reports the `apps` application as `Degraded` and `kubectl describe pod midpoint-…` shows
  `Init:CrashLoopBackOff` on the `midpoint-db-init` container while the event log records repeated `BackOff restarting failed
  container midpoint-db-init` messages.
- **Root cause**: When the database or admin passwords contained characters that are special to the shell (most commonly `$`),
  the previous init script exported them through `JAVA_OPTS`/`MP_SET_*` environment variables. The downstream `ninja.sh` wrapper
  evaluates those variables via `eval`, so Bash expanded `$` sequences (for example, `$$` became the PID). The altered password
  then failed PostgreSQL authentication, aborting the schema check/upgrade with a non-zero exit code and re-triggering the init
  container.
- **Permanent fix**: Secrets are now mounted as volumes and read directly from their files before the init container calls
  `ninja` (see `k8s/apps/midpoint/deployment.yaml`). This removes the double-parsing pitfall and lets midPoint use the literal
  secret values. The helper also masks sensitive data in the captured logs so operators still get actionable diagnostics when a
  different error occurs. It now retries `midpoint.sh init-native` and the `ninja` schema commands before giving up so a short
  database failover no longer bricks the deployment.

- **Diagnostics**: When the Argo CD `apps` application reports a degraded pod, the bootstrap workflow now dumps the `describe`
  output plus the last and previous log snippets for every init and app container. This makes the failing init container output
  immediately visible in the Action logs without having to rerun the troubleshooting steps manually.


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
