from __future__ import annotations

from typing import List, Mapping

import pytest


KEYCLOAK_MANIFEST = "gitops/apps/platform/keycloak/keycloak.yaml"
BANNED_ADDITIONAL_OPTIONS = {"db-url", "hostname-strict", "features"}


@pytest.mark.gitops
def test_keycloak_additional_options_are_typed(load_yaml):
    documents = load_yaml(KEYCLOAK_MANIFEST)
    keycloak_docs: List[Mapping[str, object]] = [doc for doc in documents if doc.get("kind") == "Keycloak"]
    assert keycloak_docs, "Keycloak manifest should contain a Keycloak resource"

    keycloak = keycloak_docs[0]
    spec = keycloak.get("spec", {})
    image = spec.get("image", "")
    assert ":" in image, "Keycloak image must include an explicit tag"
    options = spec.get("additionalOptions", [])
    option_names = {option.get("name") for option in options if isinstance(option, Mapping)}

    assert BANNED_ADDITIONAL_OPTIONS.isdisjoint(option_names), (
        "Keycloak additionalOptions must avoid legacy CLI flags: "
        f"{', '.join(sorted(BANNED_ADDITIONAL_OPTIONS & option_names))}"
    )


@pytest.mark.gitops
def test_keycloak_uses_typed_db_configuration(load_yaml):
    documents = load_yaml(KEYCLOAK_MANIFEST)
    keycloak_docs: List[Mapping[str, object]] = [doc for doc in documents if doc.get("kind") == "Keycloak"]
    assert keycloak_docs, "Keycloak manifest should contain a Keycloak resource"

    keycloak = keycloak_docs[0]
    db_block = keycloak.get("spec", {}).get("db", {})
    assert isinstance(db_block, Mapping), "spec.db must be a mapping"
    assert "url" not in db_block, "spec.db.url must not be set; use typed host/port/database fields instead"
