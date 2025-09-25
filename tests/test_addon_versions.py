from __future__ import annotations

import re

import pytest


APPLICATION_SET = "gitops/apps/addons/applicationset.yaml"
VERSION_PATTERN = re.compile(r"^v?\d+(?:\.\d+){1,3}$")


@pytest.mark.gitops
def test_addon_charts_are_version_pinned(load_yaml) -> None:
    (appset,) = load_yaml(APPLICATION_SET)
    spec = appset.get("spec", {})
    generators = spec.get("generators", [])
    assert generators, "ApplicationSet must declare generators"

    list_generator = next(
        (generator.get("list", {}) for generator in generators if "list" in generator),
        {},
    )
    elements = list_generator.get("elements", [])
    assert elements, "ApplicationSet list generator must include chart definitions"

    for element in elements:
        name = element.get("name", "<unknown>")
        version = element.get("targetRevision")
        assert VERSION_PATTERN.match(str(version)), f"{name} chart must pin a semantic version (got: {version})"
        repo = element.get("repoURL", "")
        assert repo.startswith("https://"), f"{name} chart must use HTTPS repositories"
