from __future__ import annotations

import re

import pytest


BOOTSTRAP_SCRIPT = "scripts/bootstrap.sh"
VERSION_PATTERN = re.compile(r"ARGOCD_VERSION=\"\$\{ARGOCD_VERSION:-(?P<version>v\d+\.\d+\.\d+)\}\"")


@pytest.mark.gitops
def test_bootstrap_script_pins_argocd_version(repo_root) -> None:
    script = (repo_root / BOOTSTRAP_SCRIPT).read_text(encoding="utf-8")
    match = VERSION_PATTERN.search(script)
    assert match, "bootstrap.sh must pin a default Argo CD version"
    version = match.group("version")
    assert version.startswith("v3."), "bootstrap.sh should default to Argo CD v3.x"


@pytest.mark.gitops
def test_bootstrap_script_applies_gitops_tree(repo_root) -> None:
    script = (repo_root / BOOTSTRAP_SCRIPT).read_text(encoding="utf-8")
    assert "kubectl apply -k \"${REPO_ROOT}/gitops/argocd\"" in script
