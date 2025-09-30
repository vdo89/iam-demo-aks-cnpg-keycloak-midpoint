import argparse
from pathlib import Path

import pytest

from scripts import configure_demo_hosts as cd


def test_build_hosts_roundtrip():
    hosts = cd.build_hosts("10.0.0.1")
    assert hosts.keycloak == "kc.10.0.0.1.nip.io"
    assert hosts.midpoint == "mp.10.0.0.1.nip.io"
    assert hosts.argocd == "argocd.10.0.0.1.nip.io"


def test_write_and_read_params(tmp_path: Path):
    params = tmp_path / "params.env"
    hosts = cd.build_hosts("192.168.0.42")
    cd.write_params(params, "custom", hosts)

    text = params.read_text(encoding="utf-8")
    assert "ingressClass=custom" in text
    assert "keycloakHost=kc.192.168.0.42.nip.io" in text
    assert "argocdHost=argocd.192.168.0.42.nip.io" in text
    assert cd.read_ingress_class(params) == "custom"


def test_main_updates_env_files(monkeypatch, tmp_path: Path):
    params = tmp_path / "params.env"
    params.write_text("ingressClass=test\n", encoding="utf-8")

    bootstrap_params = tmp_path / "bootstrap_params.env"
    manifest = tmp_path / "ingress.yaml"
    manifest.write_text(
        "\n".join(
            [
                "hostname: kc.198.51.100.7.nip.io",
                "- host: mp.198.51.100.7.nip.io",
                "  some: argocd.198.51.100.7.nip.io",
            ]
        ),
        encoding="utf-8",
    )
    env_file = tmp_path / "github_env"
    out_file = tmp_path / "github_output"
    monkeypatch.setenv("GITHUB_ENV", str(env_file))
    monkeypatch.setenv("GITHUB_OUTPUT", str(out_file))

    monkeypatch.setattr(cd, "resolve_ingress_ip", lambda *args, **kwargs: "203.0.113.10")
    monkeypatch.setattr(cd, "ensure_ingress_accessible", lambda *args, **kwargs: None)

    args = argparse.Namespace(
        params_file=params,
        extra_params_file=[bootstrap_params],
        manifest_file=[manifest],
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
    bootstrap_text = bootstrap_params.read_text(encoding="utf-8")
    assert "argocdHost=argocd.203.0.113.10.nip.io" in bootstrap_text

    manifest_text = manifest.read_text(encoding="utf-8")
    assert "hostname: kc.203.0.113.10.nip.io" in manifest_text
    assert "- host: mp.203.0.113.10.nip.io" in manifest_text
    assert "some: argocd.203.0.113.10.nip.io" in manifest_text

    env_contents = env_file.read_text(encoding="utf-8")
    assert env_contents.strip().endswith("ARGOCD_HOST=argocd.203.0.113.10.nip.io")
    assert "MP_HOST=mp.203.0.113.10.nip.io" in env_contents

    output_contents = out_file.read_text(encoding="utf-8")
    assert "midpoint_url=http://mp.203.0.113.10.nip.io/midpoint" in output_contents
    assert "argocd_url=http://argocd.203.0.113.10.nip.io" in output_contents


def test_resolve_ingress_ip_explicit():
    assert cd.resolve_ingress_ip(cd.DEFAULT_SERVICE, "198.51.100.5", None) == "198.51.100.5"


def test_resolve_ingress_ip_requires_address(monkeypatch):
    monkeypatch.setattr(cd, "run_kubectl_jsonpath", lambda *args, **kwargs: "")
    with pytest.raises(RuntimeError):
        cd.resolve_ingress_ip(cd.DEFAULT_SERVICE, None, None)


def test_ensure_ingress_accessible_rejects_private_ip():
    with pytest.raises(RuntimeError) as excinfo:
        cd.ensure_ingress_accessible("10.0.0.4")
    assert "non-public IP" in str(excinfo.value)


def test_ensure_ingress_accessible_requires_open_port(monkeypatch):
    attempts = []

    def fake_create_connection(address, timeout):
        attempts.append((address, timeout))
        raise OSError("connection refused")

    monkeypatch.setattr(cd.socket, "create_connection", fake_create_connection)

    with pytest.raises(RuntimeError) as excinfo:
        cd.ensure_ingress_accessible("1.2.3.4")

    assert "Unable to reach" in str(excinfo.value)
    assert attempts
