from __future__ import annotations

import pathlib

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_yaml(path: pathlib.Path):
    text = path.read_text(encoding="utf-8")
    text = text.replace("values: |\n{{ toYaml .values | indent 12 }}\n", "values: {}\n")
    if "\ntemplate:" in text:
        text = text.split("\ntemplate:", 1)[0] + "\n"
    return yaml.safe_load(text)


def test_platform_applicationset_versions():
    manifest = load_yaml(REPO_ROOT / "gitops/clusters/aks/apps/platform-charts.applicationset.yaml")
    elements = manifest["spec"]["generators"][0]["list"]["elements"]
    assert {item["name"] for item in elements} == {"cert-manager", "cloudnative-pg", "ingress-nginx"}

    indexed = {item["name"]: item for item in elements}
    assert indexed["cert-manager"]["targetRevision"] == "v1.18.2"
    assert indexed["cloudnative-pg"]["targetRevision"] == "0.26.0"
    assert indexed["ingress-nginx"]["targetRevision"] == "4.13.2"


def test_iam_application_uses_placeholders():
    app = load_yaml(REPO_ROOT / "gitops/clusters/aks/apps/iam.application.yaml")
    source = app["spec"]["source"]
    assert source["repoURL"] == "$(GITOPS_REPO_URL)"
    assert source["targetRevision"] == "$(GITOPS_TARGET_REVISION)"
    assert app["spec"]["syncPolicy"]["automated"]["prune"] is True


def test_iam_application_repo_vars_are_kustomize_aware():
    apps_dir = REPO_ROOT / "gitops/clusters/aks/apps"
    kustomization = yaml.safe_load((apps_dir / "kustomization.yaml").read_text(encoding="utf-8"))
    assert "configurations" in kustomization
    assert "kustomizeconfig.yaml" in kustomization["configurations"]

    config = yaml.safe_load((apps_dir / "kustomizeconfig.yaml").read_text(encoding="utf-8"))
    var_refs = config["varReference"]

    def has_var(kind: str, path: str) -> bool:
        return any(
            item.get("kind") == kind
            and item.get("path") == path
            and item.get("group") == "argoproj.io"
            for item in var_refs
        )

    assert has_var("Application", "spec/source/repoURL")
    assert has_var("Application", "spec/source/targetRevision")


def test_iam_project_repo_var_is_kustomize_aware():
    projects_dir = REPO_ROOT / "gitops/clusters/aks/projects"
    kustomization = yaml.safe_load((REPO_ROOT / "gitops/clusters/aks/kustomization.yaml").read_text(encoding="utf-8"))
    assert "configurations" in kustomization
    assert "kustomizeconfig/argocd-applications.yaml" in kustomization["configurations"]

    config = yaml.safe_load(
        (REPO_ROOT / "gitops/clusters/aks/kustomizeconfig/argocd-applications.yaml").read_text(encoding="utf-8")
    )
    var_refs = config["varReference"]

    def has_var(kind: str, path: str) -> bool:
        return any(
            item.get("kind") == kind
            and item.get("path") == path
            and item.get("group") == "argoproj.io"
            for item in var_refs
        )

    assert has_var("AppProject", "spec/sourceRepos")

    project = load_yaml(projects_dir / "iam.yaml")
    assert "$(GITOPS_REPO_URL)" in project["spec"]["sourceRepos"]


def test_params_env_defaults():
    params = (REPO_ROOT / "gitops/apps/iam/params.env").read_text(encoding="utf-8")
    assert "ingressClass=" in params
    assert "keycloakHost=" in params
    assert "midpointHost=" in params
    assert "argocdHost=" in params


def test_iam_ingress_replacements_cover_all_targets():
    kustomization = yaml.safe_load(
        (REPO_ROOT / "gitops/apps/iam/kustomization.yaml").read_text(encoding="utf-8")
    )

    def has_replacement(source_field: str, kind: str, name: str, field_path: str) -> bool:
        for entry in kustomization.get("replacements", []):
            src = entry.get("source", {})
            if src.get("fieldPath") != source_field:
                continue
            for target in entry.get("targets", []):
                selector = target.get("select", {})
                if selector.get("kind") == kind and selector.get("name") == name:
                    if field_path in target.get("fieldPaths", []):
                        return True
        return False

    assert has_replacement("data.ingressClass", "Keycloak", "rws-keycloak", "spec.ingress.ingressClassName")
    assert has_replacement("data.ingressClass", "Ingress", "midpoint", "spec.ingressClassName")
    assert has_replacement("data.keycloakHost", "Keycloak", "rws-keycloak", "spec.hostname.hostname")
    assert has_replacement("data.midpointHost", "Ingress", "midpoint", "spec.rules.0.host")


def test_bootstrap_ingress_replacements():
    kustomization = yaml.safe_load(
        (REPO_ROOT / "gitops/clusters/aks/bootstrap/kustomization.yaml").read_text(encoding="utf-8")
    )

    def has_replacement(source_field: str, kind: str, name: str, field_path: str) -> bool:
        for entry in kustomization.get("replacements", []):
            src = entry.get("source", {})
            if src.get("fieldPath") != source_field:
                continue
            for target in entry.get("targets", []):
                selector = target.get("select", {})
                if selector.get("kind") == kind and selector.get("name") == name:
                    if field_path in target.get("fieldPaths", []):
                        return True
        return False

    assert has_replacement("data.ingressClass", "Ingress", "argocd-server", "spec.ingressClassName")
    assert has_replacement("data.argocdHost", "Ingress", "argocd-server", "spec.rules.0.host")

    ingress = load_yaml(REPO_ROOT / "gitops/clusters/aks/bootstrap/argocd-ingress.yaml")
    backend = (
        ingress["spec"]["rules"][0]["http"]["paths"][0]["backend"]["service"]
    )
    assert backend["port"].get("name") == "http"


def test_iam_secret_generators_use_opaque_type():
    kustomization = yaml.safe_load(
        (REPO_ROOT / "gitops/apps/iam/secrets/kustomization.yaml").read_text(encoding="utf-8")
    )
    secrets = kustomization.get("secretGenerator", [])
    assert secrets, "secretGenerator entries should be defined for IAM secrets"
    for secret in secrets:
        assert secret.get("type") == "Opaque"


def test_midpoint_env_requires_tls():
    kustomization = yaml.safe_load(
        (REPO_ROOT / "gitops/apps/iam/midpoint/kustomization.yaml").read_text(encoding="utf-8")
    )
    generators = kustomization.get("configMapGenerator", [])
    midpoint_env = next((item for item in generators if item.get("name") == "midpoint-env"), None)
    assert midpoint_env is not None, "midpoint-env configMap generator must be defined"
    literals = midpoint_env.get("literals", [])
    assert "MIDPOINT_DB_SSLMODE=require" in literals


def test_cnpg_cluster_handles_missing_crds_and_roles():
    cluster = load_yaml(REPO_ROOT / "gitops/apps/iam/cnpg/cluster.yaml")
    annotations = cluster["metadata"].get("annotations", {})
    assert (
        annotations.get("argocd.argoproj.io/sync-options")
        == "SkipDryRunOnMissingResource=true"
    ), "Cluster must skip dry-run until CNPG CRDs register"

    roles = cluster["spec"].get("managed", {}).get("roles", [])

    def find_role(name: str):
        return next((role for role in roles if role.get("name") == name), None)

    app_role = find_role("app")
    assert app_role is not None, "app role should be managed for Keycloak"
    assert app_role.get("passwordSecret", {}).get("name") == "iam-db-app"

    midpoint_role = find_role("midpoint")
    assert midpoint_role is not None, "midpoint role should remain managed"
    assert midpoint_role.get("passwordSecret", {}).get("name") == "midpoint-db-app"


def test_cnpg_databases_skip_dry_run():
    for manifest_name in ("database-keycloak.yaml", "database-midpoint.yaml"):
        manifest = load_yaml(REPO_ROOT / "gitops/apps/iam/cnpg" / manifest_name)
        annotations = manifest["metadata"].get("annotations", {})
        assert (
            annotations.get("argocd.argoproj.io/sync-options")
            == "SkipDryRunOnMissingResource=true"
        ), f"{manifest_name} must skip dry-run until CNPG CRDs register"
