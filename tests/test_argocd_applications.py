from __future__ import annotations

from typing import Mapping

import pytest


ARGOCD_APPLICATIONS = (
    "gitops/argocd/addons.yaml",
    "gitops/argocd/platform.yaml",
)


def _assert_application_basics(application: Mapping[str, object]) -> None:
    assert application.get("kind") == "Application", "Expected an Argo CD Application"
    spec = application.get("spec", {})
    assert spec.get("project") == "default", "Applications should target the default project unless customized"
    source = spec.get("source", {})
    assert source.get("targetRevision") == "main", "Applications must track the main branch"
    assert "path" in source, "Applications must reference a path within the repository"
    sync_policy = spec.get("syncPolicy", {})
    sync_options = sync_policy.get("syncOptions", [])
    assert "CreateNamespace=true" in sync_options, "Applications must auto-create target namespaces"


@pytest.mark.gitops
@pytest.mark.parametrize("manifest", ARGOCD_APPLICATIONS)
def test_argocd_applications_follow_gitops_conventions(load_yaml, manifest: str) -> None:
    documents = load_yaml(manifest)
    assert documents, f"{manifest} should contain at least one manifest"
    for application in documents:
        _assert_application_basics(application)


@pytest.mark.gitops
def test_addons_application_points_to_gitops_tree(load_yaml) -> None:
    (application,) = load_yaml("gitops/argocd/addons.yaml")
    path = application["spec"]["source"]["path"]
    assert path.startswith("gitops/"), "Addons application must live under the gitops/ directory"


@pytest.mark.gitops
def test_platform_application_points_to_gitops_tree(load_yaml) -> None:
    (application,) = load_yaml("gitops/argocd/platform.yaml")
    path = application["spec"]["source"]["path"]
    assert path.startswith("gitops/"), "Platform application must live under the gitops/ directory"
