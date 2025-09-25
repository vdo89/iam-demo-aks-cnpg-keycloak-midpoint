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


def test_params_env_defaults():
    params = (REPO_ROOT / "gitops/apps/iam/params.env").read_text(encoding="utf-8")
    assert "ingressClass=" in params
    assert "keycloakHost=" in params
    assert "midpointHost=" in params
