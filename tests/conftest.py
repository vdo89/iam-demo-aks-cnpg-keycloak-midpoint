from __future__ import annotations

from pathlib import Path
from typing import Callable, List, MutableMapping

import pytest
import yaml


def _load_yaml_documents(path: Path) -> List[MutableMapping[str, object]]:
    documents = [doc for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")) if doc]
    return [dict(doc) for doc in documents]


@pytest.fixture(scope="session")
def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


@pytest.fixture(scope="session")
def load_yaml(repo_root: Path) -> Callable[[str], List[MutableMapping[str, object]]]:
    def _loader(relative_path: str) -> List[MutableMapping[str, object]]:
        return _load_yaml_documents(repo_root / relative_path)

    return _loader
