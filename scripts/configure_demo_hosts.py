#!/usr/bin/env python3
"""Discover ingress hosts and update the GitOps parameters file."""
from __future__ import annotations

import argparse
import contextlib
import ipaddress
import os
import re
import socket
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional

DEFAULT_PARAMS_FILE = Path("gitops/apps/iam/params.env")
DEFAULT_EXTRA_PARAMS_FILES = [Path("gitops/clusters/aks/bootstrap/params.env")]
DEFAULT_SERVICE = "ingress-nginx/ingress-nginx-controller"
DEFAULT_MANIFEST_FILES = [
    Path("gitops/apps/iam/keycloak/keycloak.yaml"),
    Path("gitops/apps/iam/keycloak/ingress.yaml"),
    Path("gitops/apps/iam/midpoint/ingress.yaml"),
    Path("gitops/clusters/aks/bootstrap/argocd-ingress.yaml"),
]
DEFAULT_VALIDATION_PATHS = [Path("gitops")]


@dataclass
class Hosts:
    keycloak: str
    midpoint: str
    argocd: str


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
        stderr = proc.stderr.strip()
        stdout = proc.stdout.strip()
        details = [
            f"kubectl command {' '.join(cmd)} exited with status {proc.returncode}.",
        ]
        if stderr:
            details.append(f"stderr: {stderr}")
        if stdout:
            details.append(f"stdout: {stdout}")
        raise KubectlError(" ".join(details))
    return proc.stdout.strip()


def _split_candidates(raw: str) -> list[str]:
    """Return non-empty values from a kubectl jsonpath string."""

    if not raw:
        return []
    return [value for value in re.split(r"[\s,]+", raw.strip()) if value]


def resolve_ingress_ip(service: str, explicit_ip: Optional[str], explicit_hostname: Optional[str]) -> str:
    """Discover the ingress IP using kubectl or supplied overrides."""
    if explicit_ip:
        ipaddress.ip_address(explicit_ip)  # validate format
        return explicit_ip

    try:
        ip_values = run_kubectl_jsonpath(service, "{.status.loadBalancer.ingress[*].ip}")
    except KubectlError:
        ip_values = ""

    for candidate in reversed(_split_candidates(ip_values)):
        try:
            ipaddress.ip_address(candidate)
        except ValueError:
            continue
        return candidate

    hostname_candidates: list[str] = []
    if explicit_hostname:
        hostname_candidates.append(explicit_hostname)

    try:
        hostname_values = run_kubectl_jsonpath(service, "{.status.loadBalancer.ingress[*].hostname}")
    except KubectlError:
        hostname_values = ""

    hostname_candidates.extend(_split_candidates(hostname_values))

    for hostname in hostname_candidates:
        try:
            return socket.gethostbyname(hostname)
        except OSError:
            continue

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


def build_hosts(ip: str) -> Hosts:
    """Return nip.io hosts for the provided IP address."""
    ipaddress.ip_address(ip)
    return Hosts(
        keycloak=f"kc.{ip}.nip.io",
        midpoint=f"mp.{ip}.nip.io",
        argocd=f"argocd.{ip}.nip.io",
    )


def ensure_ingress_accessible(
    ip: str, *, ports: Iterable[int] = (80, 443), raise_on_error: bool = True
) -> None:
    """Validate the ingress endpoint resolves to a reachable public address."""

    ip_obj = ipaddress.ip_address(ip)
    if (
        ip_obj.is_private
        or ip_obj.is_loopback
        or ip_obj.is_link_local
        or ip_obj.is_multicast
        or ip_obj.is_unspecified
    ):
        raise RuntimeError(
            "Ingress controller resolved to a non-public IP address"
            f" ({ip_obj}). Ensure the service publishes an external address or"
            " override it with --ingress-ip/--ingress-hostname."
        )

    connection_errors: dict[int, Exception] = {}
    for port in ports:
        try:
            with contextlib.closing(
                socket.create_connection((str(ip_obj), port), timeout=5)
            ):
                print(
                    f"✅ Verified ingress load balancer {ip_obj} accepts TCP connections on port {port}",
                    flush=True,
                )
                return
        except OSError as exc:
            connection_errors[port] = exc

    joined_errors = "; ".join(f"{port}/tcp: {err}" for port, err in connection_errors.items())
    message = (
        "Unable to reach the ingress load balancer at"
        f" {ip_obj}; attempted ports {', '.join(str(p) for p in ports)}."
        f" Connection errors: {joined_errors}."
    )

    if raise_on_error:
        raise RuntimeError(message)

    print(f"WARNING: {message}", file=sys.stderr)


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
                f"argocdHost={hosts.argocd}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )


def update_manifest_hosts(manifest_files: Iterable[Path], hosts: Hosts) -> None:
    """Update nip.io host references within manifest files."""

    replacements = [
        (re.compile(r"kc\.\d+\.\d+\.\d+\.\d+\.nip\.io"), hosts.keycloak),
        (re.compile(r"mp\.\d+\.\d+\.\d+\.\d+\.nip\.io"), hosts.midpoint),
        (re.compile(r"argocd\.\d+\.\d+\.\d+\.\d+\.nip\.io"), hosts.argocd),
    ]

    for manifest in manifest_files:
        if not manifest:
            continue
        if not manifest.exists():
            continue
        original_content = manifest.read_text(encoding="utf-8")
        updated_content = original_content
        for pattern, replacement in replacements:
            updated_content = pattern.sub(replacement, updated_content)
        if updated_content != original_content:
            manifest.write_text(updated_content, encoding="utf-8")


def discover_stale_hosts(paths: Iterable[Path], expected_ip: str) -> list[tuple[Path, str]]:
    """Return references to nip.io hosts that do not match the expected IP."""

    host_pattern = re.compile(
        r"\b(?P<service>kc|mp|argocd)\."
        r"(?P<ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\.nip\.io\b"
    )
    stale: list[tuple[Path, str]] = []

    for raw_path in paths:
        if not raw_path:
            continue
        path = raw_path.resolve()
        if path.is_dir():
            candidates = (p for p in path.rglob("*") if p.is_file())
        elif path.is_file():
            candidates = [path]
        else:
            continue

        for candidate in candidates:
            try:
                contents = candidate.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                contents = candidate.read_text(encoding="utf-8", errors="ignore")
            for match in host_pattern.finditer(contents):
                if match.group("ip") != expected_ip:
                    stale.append((candidate, match.group(0)))

    return stale


def ensure_hosts_rotated(paths: Iterable[Path], expected_ip: str) -> None:
    """Fail if any managed nip.io hosts still reference an outdated IP."""

    stale = discover_stale_hosts(paths, expected_ip)
    if stale:
        formatted = "\n".join(f"  - {ref} (in {path})" for path, ref in stale)
        raise RuntimeError(
            "Found stale nip.io hostnames that do not match the ingress IP "
            f"{expected_ip}.\n{formatted}\n"
            "Update the manifests or extend --manifest-file/--validation-path"
            " arguments so scripts/configure_demo_hosts.py can manage them."
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
        "--extra-params-file",
        action="append",
        type=Path,
        default=[*DEFAULT_EXTRA_PARAMS_FILES],
        help=(
            "Additional params.env files to keep in sync with --params-file. "
            "Specify multiple times to update several files."
        ),
    )
    parser.add_argument(
        "--manifest-file",
        action="append",
        type=Path,
        default=[*DEFAULT_MANIFEST_FILES],
        help=(
            "Manifest files that contain nip.io hostnames to update alongside params files. "
            "Specify multiple times to manage additional manifests."
        ),
    )
    parser.add_argument(
        "--validation-path",
        action="append",
        type=Path,
        default=[*DEFAULT_VALIDATION_PATHS],
        help=(
            "Files or directories that must not contain stale nip.io hostnames."
            " Specify multiple times to scan additional paths."
        ),
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
    parser.add_argument(
        "--skip-reachability-check",
        action="store_true",
        help=(
            "Do not fail if the ingress load balancer ports are not reachable. "
            "The script will still verify the IP is public and emit a warning."
        ),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    ingress_class = args.ingress_class or read_ingress_class(args.params_file) or "nginx"

    ip_value = resolve_ingress_ip(args.ingress_service, args.ingress_ip, args.ingress_hostname)
    print(f"ℹ️  Discovered ingress load balancer address: {ip_value}")
    ensure_ingress_accessible(
        ip_value,
        raise_on_error=not getattr(args, "skip_reachability_check", False),
    )
    hosts = build_hosts(ip_value)

    if args.print_only:
        print(hosts.keycloak)
        print(hosts.midpoint)
        print(hosts.argocd)
        return 0

    write_params(args.params_file, ingress_class, hosts)
    for extra_file in args.extra_params_file:
        if not extra_file:
            continue
        if extra_file.resolve() == args.params_file.resolve():
            continue
        write_params(extra_file, ingress_class, hosts)

    manifest_files = getattr(args, "manifest_file", DEFAULT_MANIFEST_FILES)
    update_manifest_hosts(manifest_files, hosts)

    validation_paths = getattr(args, "validation_path", DEFAULT_VALIDATION_PATHS)
    ensure_hosts_rotated(validation_paths, ip_value)

    github_env = os.environ.get("GITHUB_ENV")
    if github_env:
        with open(github_env, "a", encoding="utf-8") as env_file:
            env_file.write(f"EXTERNAL_IP={ip_value}\n")
            env_file.write(f"KC_HOST={hosts.keycloak}\n")
            env_file.write(f"MP_HOST={hosts.midpoint}\n")
            env_file.write(f"ARGOCD_HOST={hosts.argocd}\n")

    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as output_file:
            output_file.write(f"keycloak_url=http://{hosts.keycloak}\n")
            output_file.write(f"midpoint_url=http://{hosts.midpoint}/midpoint\n")
            # Argo CD terminates TLS at the upstream service; the ingress itself
            # only serves HTTP. Surface the reachable scheme so the generated
            # URL works out of the box.
            output_file.write(f"argocd_url=http://{hosts.argocd}\n")

    print("✅ Updated ingress host configuration:")
    print(f"   Keycloak:  http://{hosts.keycloak}")
    print(f"   midPoint:  http://{hosts.midpoint}/midpoint")
    print(f"   Argo CD:   http://{hosts.argocd}")

    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entry point
    raise SystemExit(main())
