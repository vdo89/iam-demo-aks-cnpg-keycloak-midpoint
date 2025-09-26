#!/usr/bin/env python3
"""Discover ingress hosts and update the GitOps parameters file."""
from __future__ import annotations

import argparse
import ipaddress
import os
import socket
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

DEFAULT_PARAMS_FILE = Path("gitops/apps/iam/params.env")
DEFAULT_SERVICE = "ingress-nginx/ingress-nginx-controller"


@dataclass
class Hosts:
    keycloak: str
    midpoint: str


class KubectlError(RuntimeError):
    """Raised when kubectl returns a non-zero exit status."""


def _format_kubectl_resource(service: str) -> tuple[str, str]:
    """Return the namespace and resource reference for kubectl."""

    parts = service.split("/")
    if len(parts) == 2:
        namespace, name = parts
        resource = f"service/{name}"
    elif len(parts) == 3:
        namespace, resource_type, name = parts
        resource = f"{resource_type}/{name}"
    else:  # pragma: no cover - guarded by CLI argument contract
        raise ValueError(
            "--ingress-service must be <namespace>/<name> or <namespace>/<resource>/<name>"
        )

    return namespace, resource


def run_kubectl_jsonpath(service: str, jsonpath: str) -> str:
    """Return the kubectl jsonpath result or raise KubectlError."""
    namespace, resource = _format_kubectl_resource(service)
    cmd = ["kubectl", "-n", namespace, "get", resource, "-o", f"jsonpath={jsonpath}"]
    proc = subprocess.run(cmd, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise KubectlError(proc.stderr.strip() or "kubectl command failed")
    return proc.stdout.strip()


def resolve_ingress_ip(service: str, explicit_ip: Optional[str], explicit_hostname: Optional[str]) -> str:
    """Discover the ingress IP using kubectl or supplied overrides."""
    if explicit_ip:
        ipaddress.ip_address(explicit_ip)  # validate format
        return explicit_ip

    jsonpath_ip = "{.status.loadBalancer.ingress[0].ip}"
    jsonpath_hostname = "{.status.loadBalancer.ingress[0].hostname}"

    try:
        ip_value = run_kubectl_jsonpath(service, jsonpath_ip)
    except KubectlError:
        ip_value = ""

    if ip_value:
        return ip_value

    hostname = explicit_hostname
    if not hostname:
        try:
            hostname = run_kubectl_jsonpath(service, jsonpath_hostname)
        except KubectlError:
            hostname = ""

    if not hostname:
        status_hint = ""
        try:
            svc_type = run_kubectl_jsonpath(service, "{.spec.type}")
        except KubectlError as exc:
            svc_type = ""
            status_hint = f" Unable to query service type: {exc}."
        try:
            lb_state = run_kubectl_jsonpath(service, "{.status.loadBalancer}")
        except KubectlError as exc:
            lb_state = ""
            status_hint = f"{status_hint} Unable to query load balancer status: {exc}."
        else:
            if lb_state:
                status_hint = f"{status_hint} Current loadBalancer status: {lb_state}."
        if svc_type:
            status_hint = f"{status_hint} Service type: {svc_type}."
        raise RuntimeError(
            "Ingress controller does not expose an external IP or hostname yet. "
            "Provide --ingress-ip or wait for the service to publish an address." + status_hint
        )

    try:
        return socket.gethostbyname(hostname)
    except OSError as exc:  # pragma: no cover - network behaviour varies per environment
        raise RuntimeError(f"Unable to resolve hostname {hostname!r}: {exc}") from exc


def build_hosts(ip: str) -> Hosts:
    """Return nip.io hosts for the provided IP address."""
    ipaddress.ip_address(ip)
    return Hosts(keycloak=f"kc.{ip}.nip.io", midpoint=f"mp.{ip}.nip.io")


def read_ingress_class(params_file: Path) -> Optional[str]:
    if not params_file.exists():
        return None
    for line in params_file.read_text(encoding="utf-8").splitlines():
        if line.startswith("ingressClass="):
            return line.split("=", 1)[1].strip()
    return None


def write_params(params_file: Path, ingress_class: str, hosts: Hosts) -> None:
    params_file.parent.mkdir(parents=True, exist_ok=True)
    params_file.write_text(
        "\n".join(
            [
                "# Ingress parameters for the IAM demo environment.",
                "# Hosts rotate via scripts/configure_demo_hosts.py; update ingressClass here if",
                "# your cluster uses a different controller.",
                f"ingressClass={ingress_class}",
                f"keycloakHost={hosts.keycloak}",
                f"midpointHost={hosts.midpoint}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--params-file",
        type=Path,
        default=DEFAULT_PARAMS_FILE,
        help="Path to the params.env file to update",
    )
    parser.add_argument(
        "--ingress-service",
        default=DEFAULT_SERVICE,
        help="Ingress resource in <namespace>/<name> or <namespace>/<resource>/<name> form",
    )
    parser.add_argument("--ingress-ip", help="Explicit ingress IP address (skips kubectl)")
    parser.add_argument("--ingress-hostname", help="Explicit ingress hostname to resolve")
    parser.add_argument("--ingress-class", help="IngressClass to record in params.env")
    parser.add_argument(
        "--print-only",
        action="store_true",
        help="Do not modify the params file; print discovered hosts instead",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    ingress_class = args.ingress_class or read_ingress_class(args.params_file) or "nginx"

    ip_value = resolve_ingress_ip(args.ingress_service, args.ingress_ip, args.ingress_hostname)
    hosts = build_hosts(ip_value)

    if args.print_only:
        print(hosts.keycloak)
        print(hosts.midpoint)
        return 0

    write_params(args.params_file, ingress_class, hosts)

    github_env = os.environ.get("GITHUB_ENV")
    if github_env:
        with open(github_env, "a", encoding="utf-8") as env_file:
            env_file.write(f"EXTERNAL_IP={ip_value}\n")
            env_file.write(f"KC_HOST={hosts.keycloak}\n")
            env_file.write(f"MP_HOST={hosts.midpoint}\n")

    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as output_file:
            output_file.write(f"keycloak_url=http://{hosts.keycloak}\n")
            output_file.write(f"midpoint_url=http://{hosts.midpoint}/midpoint\n")

    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entry point
    raise SystemExit(main())
