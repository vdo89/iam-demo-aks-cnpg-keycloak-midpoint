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
        validation_path=[tmp_path],
        ingress_service=cd.DEFAULT_SERVICE,
        ingress_ip=None,
        ingress_hostname=None,
        ingress_class=None,
        print_only=False,
        skip_reachability_check=False,
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


def test_discover_stale_hosts(tmp_path: Path):
    tracked = tmp_path / "manifests"
    tracked.mkdir()
    file_one = tracked / "kc.yaml"
    file_one.write_text("hostname: kc.192.0.2.4.nip.io", encoding="utf-8")
    file_two = tracked / "other.txt"
    file_two.write_text("argocd.203.0.113.8.nip.io", encoding="utf-8")

    stale = cd.discover_stale_hosts([tracked], "203.0.113.8")
    assert stale == [(file_one.resolve(), "kc.192.0.2.4.nip.io")]
    with pytest.raises(RuntimeError) as excinfo:
        cd.ensure_hosts_rotated([tracked], "203.0.113.8")
    assert "kc.192.0.2.4.nip.io" in str(excinfo.value)

    # When the inputs only contain the expected IP, the result is empty.
    file_one.write_text("hostname: kc.203.0.113.8.nip.io", encoding="utf-8")
    stale = cd.discover_stale_hosts([tracked], "203.0.113.8")
    assert stale == []
    cd.ensure_hosts_rotated([tracked], "203.0.113.8")


def test_resolve_ingress_ip_explicit():
    assert cd.resolve_ingress_ip(cd.DEFAULT_SERVICE, "198.51.100.5", None) == "198.51.100.5"


def test_resolve_ingress_ip_requires_address(monkeypatch):
    monkeypatch.setattr(cd, "run_kubectl_jsonpath", lambda *args, **kwargs: "")
    with pytest.raises(RuntimeError):
        cd.resolve_ingress_ip(cd.DEFAULT_SERVICE, None, None)


def test_resolve_ingress_ip_prefers_latest_candidate(monkeypatch):
    def fake_jsonpath(service: str, query: str) -> str:
        if query == "{.status.loadBalancer.ingress[*].ip}":
            return "198.51.100.7 203.0.113.10"
        if query == "{.status.loadBalancer.ingress[*].hostname}":
            return "old.example.com new.example.com"
        return ""

    monkeypatch.setattr(cd, "run_kubectl_jsonpath", fake_jsonpath)

    assert cd.resolve_ingress_ip(cd.DEFAULT_SERVICE, None, None) == "203.0.113.10"


def test_run_kubectl_jsonpath_surfaces_failures(monkeypatch):
    def fake_run(cmd, check, stdout, stderr, text):
        class Result:
            returncode = 1
            stdout = ""
            stderr = "resource not found"

        return Result()

    monkeypatch.setattr(cd.subprocess, "run", fake_run)

    with pytest.raises(cd.KubectlError) as excinfo:
        cd.run_kubectl_jsonpath("iam/service/missing", "{.status}")

    message = str(excinfo.value)
    assert "kubectl command kubectl -n iam get service/missing -o jsonpath={.status}" in message
    assert "status 1" in message
    assert "resource not found" in message


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
