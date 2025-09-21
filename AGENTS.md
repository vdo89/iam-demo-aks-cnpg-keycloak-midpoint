# Agent Instructions
GitOps‑first • Shift‑left governance • Strongly‑typed • Composable • Idempotent
1) Non‑negotiables
GitOps by default
Desired state lives in Git. CI writes to Git; controllers (Argo CD, operators) reconcile clusters. No imperative changes to prod from CI (break‑glass is documented, audited, and leaves the repo convergent).
Outcome: reproducible, reviewable changes with full provenance.
Shift‑left governance (metadata as code)
Governance metadata (owners, domains, glossary terms, tags/classifications, deprecation states) is declared alongside schemas and interfaces, not retrofitted. Use schema annotations (Avro/Protobuf/JSON Schema) so ownership, glossary, and policies travel with the schema and are enforced in PRs. 
Strongly‑typed all the way down
Prefer typed interfaces with machine‑checkable schemas: OpenAPI/CRDs (with validation), JSON Schema, Avro/Protobuf, CUE, TypeScript types. CI fails on unknown/invalid fields; run kubeconform --strict on rendered manifests.
Composable building blocks (category‑theoretic intuition)
Build small, pure transforms that compose: render (values→manifests) ∘ validate ∘ policy ∘ reconcile. Composition is associative; there’s an identity (empty overlay/values) and repeated application is idempotent. Treat schemas as structures and instances as structure‑preserving mappings—this keeps transforms predictable and composable. 
Secure by construction
Secrets via External Secrets / SOPS / Sealed Secrets; OIDC to clouds; sign & verify (e.g., cosign). Policy‑as‑code (OPA/Conftest/Gatekeeper) runs in CI and at admission.
Pinned & reproducible
Pin chart/operator/image versions; commit lockfiles and digests. Re‑renders produce identical output from the same Git ref.
- When updating GitHub Actions workflows in `.github/workflows`, use `shell: bash` for multi-line scripts that rely on Bash features and enable `set -euo pipefail` within those scripts. Provide helpful logging and retries for Kubernetes operations so that transient controller issues are easier to diagnose.
- Keep Kubernetes manifests and automation in sync: whenever a manifest references a secret or configmap, ensure the corresponding bootstrap automation creates or validates it.
- Run `terraform fmt` on files under `infra/azure/terraform` after making Terraform changes.
- Document meaningful behavioral changes to the deployment process in `README.md` when it helps operators understand new requirements.
