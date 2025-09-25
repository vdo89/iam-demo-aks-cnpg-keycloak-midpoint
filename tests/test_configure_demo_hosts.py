import argparse
from pathlib import Path

import pytest

from scripts import configure_demo_hosts as cd


def test_build_hosts_roundtrip():
    hosts = cd.build_hosts("10.0.0.1")
    assert hosts.keycloak == "kc.10.0.0.1.nip.io"
    assert hosts.midpoint == "mp.10.0.0.1.nip.io"


def test_write_and_read_params(tmp_path: Path):
    params = tmp_path / "params.env"
    hosts = cd.build_hosts("192.168.0.42")
    cd.write_params(params, "custom", hosts)

    text = params.read_text(encoding="utf-8")
    assert "ingressClass=custom" in text
    assert "keycloakHost=kc.192.168.0.42.nip.io" in text
    assert cd.read_ingress_class(params) == "custom"


def test_main_updates_env_files(monkeypatch, tmp_path: Path):
    params = tmp_path / "params.env"
    params.write_text("ingressClass=test\n", encoding="utf-8")

    env_file = tmp_path / "github_env"
    out_file = tmp_path / "github_output"
    monkeypatch.setenv("GITHUB_ENV", str(env_file))
    monkeypatch.setenv("GITHUB_OUTPUT", str(out_file))

    monkeypatch.setattr(cd, "resolve_ingress_ip", lambda *args, **kwargs: "203.0.113.10")

    args = argparse.Namespace(
        params_file=params,
        ingress_service=cd.DEFAULT_SERVICE,
        ingress_ip=None,
        ingress_hostname=None,
        ingress_class=None,
        print_only=False,
    )
    monkeypatch.setattr(cd, "parse_args", lambda: args)

    assert cd.main() == 0

    saved = params.read_text(encoding="utf-8")
    assert "keycloakHost=kc.203.0.113.10.nip.io" in saved
    assert env_file.read_text(encoding="utf-8").strip().endswith("MP_HOST=mp.203.0.113.10.nip.io")
    assert "midpoint_url=http://mp.203.0.113.10.nip.io/midpoint" in out_file.read_text(encoding="utf-8")


def test_resolve_ingress_ip_explicit():
    assert cd.resolve_ingress_ip(cd.DEFAULT_SERVICE, "198.51.100.5", None) == "198.51.100.5"


def test_resolve_ingress_ip_requires_address(monkeypatch):
    monkeypatch.setattr(cd, "run_kubectl_jsonpath", lambda *args, **kwargs: "")
    with pytest.raises(RuntimeError):
        cd.resolve_ingress_ip(cd.DEFAULT_SERVICE, None, None)
