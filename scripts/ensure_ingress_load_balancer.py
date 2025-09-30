#!/usr/bin/env python3
"""Ensure the ingress controller exposes a reachable Azure load balancer."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Iterable, Optional
from pathlib import Path

if __package__ in (None, ""):
    # Allow running the script directly via ``python scripts/<name>.py`` by ensuring the
    # repository root (which contains the ``scripts`` package) is on ``sys.path``.
    repo_root = Path(__file__).resolve().parent.parent
    if str(repo_root) not in sys.path:
        sys.path.insert(0, str(repo_root))

from scripts.configure_demo_hosts import DEFAULT_SERVICE, KubectlError, run_kubectl_jsonpath


class AzureCliError(RuntimeError):
    """Raised when the Azure CLI exits with a non-zero status."""


def _run_command(cmd: Iterable[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    """Execute *cmd* and optionally raise if it fails."""

    proc = subprocess.run(
        list(cmd),
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"Command {' '.join(cmd)} failed with exit code {proc.returncode}: {proc.stderr.strip()}"
        )
    return proc


def _run_az(cmd: Iterable[str]) -> subprocess.CompletedProcess[str]:
    """Execute an Azure CLI command and raise :class:`AzureCliError` on failure."""

    proc = _run_command(("az", *cmd), check=False)
    if proc.returncode != 0:
        raise AzureCliError(proc.stderr.strip() or "Azure CLI command failed")
    return proc


def _parse_service(service: str) -> tuple[str, str]:
    """Return the namespace and name components of an ingress service reference."""

    parts = service.split("/")
    if len(parts) == 2:
        namespace, name = parts
    elif len(parts) == 3:
        namespace, _resource_type, name = parts
    else:  # pragma: no cover - validated by CLI contract
        raise ValueError(
            "--ingress-service must be <namespace>/<name> or <namespace>/<resource>/<name>"
        )
    return namespace, name


def _kubectl_json(namespace: str, name: str) -> dict:
    """Return the Kubernetes service definition as a dictionary."""

    proc = _run_command(
        ["kubectl", "-n", namespace, "get", f"service/{name}", "-o", "json"],
        check=False,
    )
    if proc.returncode != 0:
        raise KubectlError(proc.stderr.strip() or "kubectl command failed")
    return json.loads(proc.stdout)


def _patch_service(namespace: str, name: str, patch: dict) -> None:
    """Apply a strategic merge patch to the service."""

    payload = json.dumps(patch)
    _run_command(
        [
            "kubectl",
            "-n",
            namespace,
            "patch",
            f"service/{name}",
            "--type",
            "merge",
            "-p",
            payload,
        ]
    )


def _ensure_service_type(service: dict, namespace: str, name: str) -> bool:
    """Ensure the service type is ``LoadBalancer``; return ``True`` if patched."""

    if service.get("spec", {}).get("type") == "LoadBalancer":
        return False
    print(
        f"ℹ️  Updating {namespace}/{name} service type from"
        f" {service.get('spec', {}).get('type', 'unknown')} to LoadBalancer",
        flush=True,
    )
    _patch_service(namespace, name, {"spec": {"type": "LoadBalancer"}})
    return True


def _ensure_annotation(service: dict, namespace: str, name: str, key: str, value: str) -> bool:
    """Ensure the service annotation *key* equals *value*; return ``True`` if patched."""

    metadata = service.setdefault("metadata", {})
    annotations = metadata.setdefault("annotations", {})
    if annotations.get(key) == value:
        return False
    print(
        f"ℹ️  Setting annotation {key}={value!r} on service {namespace}/{name}",
        flush=True,
    )
    _patch_service(namespace, name, {"metadata": {"annotations": {key: value}}})
    return True


def _wait_for_load_balancer(service: str, timeout: int, interval: int) -> None:
    """Wait until the service exposes an external IP or hostname."""

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            ip_value = run_kubectl_jsonpath(service, "{.status.loadBalancer.ingress[0].ip}")
        except KubectlError:
            ip_value = ""
        if ip_value:
            print(f"✅ Load balancer exposes external IP {ip_value}", flush=True)
            return
        try:
            hostname_value = run_kubectl_jsonpath(
                service, "{.status.loadBalancer.ingress[0].hostname}"
            )
        except KubectlError:
            hostname_value = ""
        if hostname_value:
            print(f"✅ Load balancer exposes hostname {hostname_value}", flush=True)
            return
        time.sleep(interval)
    raise RuntimeError(
        "Timed out waiting for the ingress load balancer to publish an external IP or hostname"
    )


def _emit_azure_diagnostics(node_resource_group: str) -> None:
    """Surface Azure load balancer diagnostics to aid troubleshooting."""

    print("::group::Azure load balancer diagnostics", flush=True)
    try:
        public_ip_proc = _run_az(
            (
                "network",
                "public-ip",
                "list",
                "--resource-group",
                node_resource_group,
                "--query",
                "[].{name:name, ipAddress:ipAddress, provisioningState:provisioningState}",
                "-o",
                "table",
            )
        )
        print("📡 Public IP addresses:")
        print(public_ip_proc.stdout.strip() or "(none)")
    except AzureCliError as exc:
        print(f"⚠️  Unable to list public IPs: {exc}")

    try:
        lb_proc = _run_az(
            (
                "network",
                "lb",
                "list",
                "--resource-group",
                node_resource_group,
                "--query",
                "[].{name:name, provisioningState:provisioningState}",
                "-o",
                "table",
            )
        )
        print("📦 Load balancers:")
        print(lb_proc.stdout.strip() or "(none)")
    except AzureCliError as exc:
        print(f"⚠️  Unable to list load balancers: {exc}")

    try:
        rules_proc = _run_az(
            (
                "network",
                "lb",
                "frontend-ip",
                "list",
                "--resource-group",
                node_resource_group,
                "--lb-name",
                "kubernetes",
                "-o",
                "table",
            )
        )
        print("🔀 Frontend IP configurations (kubernetes LB):")
        print(rules_proc.stdout.strip() or "(none)")
    except AzureCliError as exc:
        print(f"⚠️  Unable to inspect kubernetes load balancer frontends: {exc}")

    try:
        inbound_proc = _run_az(
            (
                "network",
                "lb",
                "rule",
                "list",
                "--resource-group",
                node_resource_group,
                "--lb-name",
                "kubernetes",
                "-o",
                "table",
            )
        )
        print("🚦 Inbound rules (kubernetes LB):")
        print(inbound_proc.stdout.strip() or "(none)")
    except AzureCliError as exc:
        print(f"⚠️  Unable to inspect kubernetes load balancer rules: {exc}")

    print("::endgroup::", flush=True)


def _discover_node_resource_group(resource_group: str, aks_name: str) -> Optional[str]:
    """Return the managed node resource group for the AKS cluster."""

    if not resource_group or not aks_name:
        return None
    try:
        proc = _run_az(
            (
                "aks",
                "show",
                "--resource-group",
                resource_group,
                "--name",
                aks_name,
                "--query",
                "nodeResourceGroup",
                "-o",
                "tsv",
            )
        )
    except AzureCliError as exc:
        print(f"⚠️  Unable to discover node resource group: {exc}")
        return None
    node_rg = proc.stdout.strip()
    if node_rg:
        print(f"ℹ️  AKS node resource group: {node_rg}", flush=True)
    return node_rg or None


@dataclass
class EnsureOptions:
    service: str
    resource_group: Optional[str]
    aks_name: Optional[str]
    timeout: int
    interval: int


def parse_args(argv: Optional[Iterable[str]] = None) -> EnsureOptions:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--ingress-service",
        default=DEFAULT_SERVICE,
        help="Ingress service reference (<namespace>/<name> or <namespace>/<resource>/<name>)",
    )
    parser.add_argument(
        "--resource-group",
        default=os.environ.get("RESOURCE_GROUP"),
        help="Azure resource group that contains the AKS control plane",
    )
    parser.add_argument(
        "--aks-name",
        default=os.environ.get("AKS_NAME"),
        help="AKS cluster name",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=900,
        help="Seconds to wait for the load balancer to expose an address",
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=15,
        help="Polling interval in seconds while waiting for the load balancer",
    )

    args = parser.parse_args(argv)
    return EnsureOptions(
        service=args.ingress_service,
        resource_group=args.resource_group,
        aks_name=args.aks_name,
        timeout=args.timeout,
        interval=args.interval,
    )


def main(argv: Optional[Iterable[str]] = None) -> int:
    options = parse_args(argv)
    namespace, name = _parse_service(options.service)
    node_rg = _discover_node_resource_group(options.resource_group or "", options.aks_name or "")

    print(f"ℹ️  Ensuring ingress service {namespace}/{name} is backed by an Azure load balancer.")
    service = _kubectl_json(namespace, name)
    patched = False

    if _ensure_service_type(service, namespace, name):
        patched = True
        service = _kubectl_json(namespace, name)

    if node_rg:
        annotation_key = "service.beta.kubernetes.io/azure-load-balancer-resource-group"
        if _ensure_annotation(service, namespace, name, annotation_key, node_rg):
            patched = True

    if patched:
        # Re-fetch to ensure we have up-to-date status for waiting.
        service = _kubectl_json(namespace, name)

    try:
        _wait_for_load_balancer(options.service, options.timeout, options.interval)
    except RuntimeError as exc:
        print(f"⚠️  {exc}")
        if node_rg:
            _emit_azure_diagnostics(node_rg)
        raise

    if node_rg:
        _emit_azure_diagnostics(node_rg)

    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entry point
    sys.exit(main())
