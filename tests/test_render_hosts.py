import sys
from pathlib import Path

import pytest
import yaml

from scripts import render_hosts


@pytest.mark.parametrize(
    "ip,expected_host",
    [
        ("1.2.3.4", "kc.1.2.3.4.nip.io"),
        ("2001:db8::1", "kc.2001:db8::1.nip.io"),
    ],
)
def test_build_params(ip, expected_host):
    content = render_hosts.build_params(ip, "nginx")
    assert expected_host in content


def test_write_params(tmp_path: Path):
    destination = tmp_path / "params.env"
    render_hosts.write_params("hello", destination)
    assert destination.read_text() == "hello"


def test_parse_ip_invalid():
    with pytest.raises(ValueError):
        render_hosts.parse_ip("not-an-ip")


def test_update_ingress_values(tmp_path: Path):
    values = tmp_path / "values.yaml"
    values.write_text(
        """
controller:
  service:
    annotations:
      existing: true
    loadBalancerIP: 1.1.1.1
"""
    )
    render_hosts.update_ingress_values("2.2.2.2", "demo-rg", values)
    data = yaml.safe_load(values.read_text())
    assert data["controller"]["service"]["loadBalancerIP"] == "2.2.2.2"
    assert (
        data["controller"]["service"]["annotations"][
            "service.beta.kubernetes.io/azure-load-balancer-resource-group"
        ]
        == "demo-rg"
    )


def test_update_requires_resource_group(monkeypatch, tmp_path: Path):
    params = tmp_path / "params.env"
    params.write_text("", encoding="utf-8")
    values = tmp_path / "values.yaml"
    values.write_text("{}", encoding="utf-8")
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "render_hosts.py",
            "--ip",
            "1.1.1.1",
            "--update-values",
            "--output",
            str(params),
            "--ingress-values",
            str(values),
        ],
    )
    with pytest.raises(SystemExit):
        render_hosts.main()
