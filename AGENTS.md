# Agent Instructions

- When updating GitHub Actions workflows in `.github/workflows`, use `shell: bash` for multi-line scripts that rely on Bash features and enable `set -euo pipefail` within those scripts. Provide helpful logging and retries for Kubernetes operations so that transient controller issues are easier to diagnose.
- Keep Kubernetes manifests and automation in sync: whenever a manifest references a secret or configmap, ensure the corresponding bootstrap automation creates or validates it.
- Run `terraform fmt` on files under `infra/azure/terraform` after making Terraform changes.
- Document meaningful behavioral changes to the deployment process in `README.md` when it helps operators understand new requirements.
