import re
from pathlib import Path
from typing import Iterable

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]


def parse_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            raise AssertionError(f"Line '{line}' in {path} is not KEY=VALUE")
        key, value = stripped.split("=", 1)
        values[key] = value
    return values


def load_yaml_documents(path: Path) -> Iterable[dict]:
    with path.open("r", encoding="utf-8") as handle:
        yield from yaml.safe_load_all(handle)


def test_keycloak_manifest_uses_typed_knobs_only() -> None:
    keycloak_manifest = REPO_ROOT / "gitops" / "iam" / "base" / "keycloak" / "keycloak.yaml"
    contents = keycloak_manifest.read_text(encoding="utf-8")

    banned_patterns = {
        re.compile(r"^\s*-?\s*name:\s*db-url\s*$", re.MULTILINE): "--db-url",
        re.compile(r"^\s*-?\s*name:\s*hostname-strict\s*$", re.MULTILINE): "--hostname-strict",
        re.compile(r"^\s*-?\s*name:\s*features\s*$", re.MULTILINE): "--features",
    }

    for pattern, flag in banned_patterns.items():
        assert not pattern.search(contents), f"Keycloak manifest must not configure {flag} via additionalOptions"

    db_block = re.search(r"^  db:\n(?P<body>(?:^(?: {4}|\t).*(?:\n|$))*)", contents, re.MULTILINE)
    assert db_block, "Keycloak manifest should keep a spec.db section so tests can verify typed settings"
    for line in db_block.group("body").splitlines():
        assert "url:" not in line.strip(), "Database connection must rely on typed fields instead of spec.db.url"


def test_cluster_overlays_override_ingress_and_storage_defaults() -> None:
    base_env = parse_env_file(REPO_ROOT / "gitops" / "iam" / "base" / "params.env")
    overlay_env = parse_env_file(REPO_ROOT / "gitops" / "iam" / "overlays" / "demo" / "params.env")

    for key in ("ingressClass", "keycloakHost", "midpointHost", "cnpgStorageAccount"):
        assert key in base_env, f"{key} missing from base params"
        assert key in overlay_env, f"{key} missing from overlay params"

    assert overlay_env["keycloakHost"].endswith(".nip.io"), "Overlay should document nip.io host pattern"
    assert overlay_env["midpointHost"].endswith(".nip.io"), "Overlay should document nip.io host pattern"
    assert overlay_env["cnpgStorageAccount"] != "changeme", "Overlay must demonstrate overriding the storage account"


def test_cluster_applications_track_new_layout() -> None:
    app_docs = list(load_yaml_documents(REPO_ROOT / "clusters" / "demo" / "applications.yaml"))
    assert len(app_docs) == 2, "Expected exactly two Argo CD Applications in the demo cluster overlay"

    paths = {doc["spec"]["source"]["path"] for doc in app_docs}
    assert "gitops/addons/base" in paths
    assert "gitops/iam/overlays/demo" in paths

    for doc in app_docs:
        source = doc["spec"]["source"]
        assert source["repoURL"] == "$(REPO_URL)", "Applications should rely on kustomize vars for repoURL"
        assert source["targetRevision"] == "$(TARGET_REVISION)", "Applications should rely on kustomize vars for revision"


def test_bootstrap_applicationset_uses_variables() -> None:
    root_appset = next(load_yaml_documents(REPO_ROOT / "gitops" / "bootstrap" / "base" / "root-applicationset.yaml"))
    spec = root_appset["spec"]
    git_generator = spec["generators"][0]["git"]
    assert git_generator["repoURL"] == "$(REPO_URL)"
    assert git_generator["revision"] == "$(TARGET_REVISION)"
    template_source = spec["template"]["spec"]["source"]
    assert template_source["repoURL"] == "$(REPO_URL)"
    assert template_source["targetRevision"] == "$(TARGET_REVISION)"


def test_addon_versions_are_pinned() -> None:
    appset = next(load_yaml_documents(REPO_ROOT / "gitops" / "addons" / "base" / "applicationset.yaml"))
    elements = appset["spec"]["generators"][0]["list"]["elements"]
    versions = {element["name"]: element["targetRevision"] for element in elements}
    assert versions["cert-manager"] == "v1.18.2"
    assert versions["cnpg-operator"] == "0.26.0"
    assert versions["ingress-nginx"] == "4.11.3"
