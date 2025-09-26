#!/usr/bin/env python3
"""Normalize Azure Storage credentials into the cnpg-azure-backup secret."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from dataclasses import dataclass
from urllib.parse import urlparse


@dataclass
class AzureCredential:
    storage_account: str
    connection_string: str
    account_key: str | None = None
    sas_token: str | None = None


def _redacted_preview(value: str) -> str:
    compact = re.sub(r"\s+", " ", value.strip())
    if not compact:
        return "<empty>"
    if len(compact) <= 6:
        return "*" * len(compact)
    prefix = compact[:4]
    suffix = compact[-2:]
    return f"{prefix}…{suffix}"


def _heuristic_summary(value: str) -> str:
    normalized_lower = value.lower()
    heuristics = {
        "has_equals": "=" in value,
        "has_newlines": "\n" in value,
        "has_question": "?" in value,
        "looks_json": value.lstrip().startswith(("{", "[")),
        "looks_url": bool(re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", value)),
        "has_accountname": "accountname" in normalized_lower,
        "has_sig": "sig=" in normalized_lower,
    }
    return ", ".join(f"{key}={'yes' if val else 'no'}" for key, val in heuristics.items())


def parse_credential(raw: str, storage_account: str) -> AzureCredential:
    value = raw.strip()
    if (value.startswith("\"") and value.endswith("\"")) or (
        value.startswith("'") and value.endswith("'")
    ):
        value = value[1:-1].strip()
    if not value:
        raise ValueError("Credential must not be empty")

    normalized_value = value.replace("\r\n", "\n").replace("\r", "\n")

    if normalized_value.lower().startswith("usedevelopmentstorage=true"):
        parts = [segment.strip() for segment in re.split(r"[;\n]+", normalized_value) if segment.strip()]
        connection_string = ";".join(parts)
        return AzureCredential(
            storage_account=storage_account,
            connection_string=connection_string,
        )
    if "=" in normalized_value and (
        ";" in normalized_value
        or "\n" in normalized_value
        or re.search(
            r"\b(accountname|accountkey|sharedaccesssignature|defaultendpointsprotocol|"
            r"blobendpoint|queueendpoint|tableendpoint|fileendpoint|endpointsuffix)=",
            normalized_value,
            flags=re.IGNORECASE,
        )
    ):
        parts: dict[str, tuple[str, str]] = {}
        for segment in re.split(r"[;\n]+", normalized_value):
            if not segment:
                continue
            match = re.match(r"\s*([^:=]+)\s*[:=]\s*(.*)\s*$", segment)
            if not match:
                continue
            key = match.group(1).strip()
            val = match.group(2).strip()
            if not key:
                continue
            parts[key.lower()] = (key, val)

        account = parts.get("accountname", ("AccountName", storage_account))[1]
        account_key = parts.get("accountkey", ("AccountKey", None))[1]
        sas = parts.get("sharedaccesssignature", ("SharedAccessSignature", None))[1]

        connection: list[str] = []
        if "defaultendpointsprotocol" in parts:
            original_key, proto = parts["defaultendpointsprotocol"]
            connection.append(f"{original_key}={proto}")
        else:
            connection.append("DefaultEndpointsProtocol=https")

        if account:
            connection.append(f"AccountName={account}")

        blob_endpoint = parts.get("blobendpoint")
        if blob_endpoint:
            connection.append(f"{blob_endpoint[0]}={blob_endpoint[1]}")

        if account_key:
            connection.append(f"AccountKey={account_key}")

        if sas:
            connection.append(f"SharedAccessSignature={sas}")

        if "endpointsuffix" in parts:
            suffix_key, suffix_val = parts["endpointsuffix"]
            connection.append(f"{suffix_key}={suffix_val}")
        elif not blob_endpoint:
            connection.append("EndpointSuffix=core.windows.net")

        for endpoint_key in ("queueendpoint", "tableendpoint", "fileendpoint"):
            if endpoint_key in parts:
                original_key, val = parts[endpoint_key]
                connection.append(f"{original_key}={val}")

        connection_string = ";".join(connection)
        return AzureCredential(
            storage_account=account or storage_account,
            connection_string=connection_string,
            account_key=account_key,
            sas_token=sas,
        )

    parsed_url = urlparse(value)
    url_query = parsed_url.query
    if not url_query and parsed_url.path and "?" in parsed_url.path:
        path, _, query = parsed_url.path.partition("?")
        parsed_url = parsed_url._replace(path=path)
        url_query = query

    if parsed_url.scheme and url_query:
        query_items = url_query.lower()
        if "sig=" in query_items and "sv=" in query_items:
            token = url_query
            account = storage_account
            if parsed_url.hostname:
                match = re.match(r"^(?P<name>[^.]+)\.blob\.core\.windows\.net$", parsed_url.hostname)
                if match:
                    account = match.group("name")
            if parsed_url.hostname:
                blob_endpoint = f"{parsed_url.scheme}://{parsed_url.hostname}/"
            else:
                blob_endpoint = f"https://{account}.blob.core.windows.net/"
            connection_string = (
                "DefaultEndpointsProtocol=https;"
                f"AccountName={account};"
                f"BlobEndpoint={blob_endpoint};"
                f"SharedAccessSignature={token}"
            )
            return AzureCredential(
                storage_account=account,
                connection_string=connection_string,
                sas_token=token,
            )

    token = value.lstrip("?")
    token_lower = token.lower()
    if "sig=" in token_lower and "sv=" in token_lower:
        connection_string = (
            "DefaultEndpointsProtocol=https;"
            f"AccountName={storage_account};"
            f"BlobEndpoint=https://{storage_account}.blob.core.windows.net/;"
            f"SharedAccessSignature={token}"
        )
        return AzureCredential(storage_account=storage_account, connection_string=connection_string, sas_token=token)

    base64_like = normalized_value.strip()
    if (
        base64_like
        and not re.search(r"[;&?{}\s]", base64_like)
        and "=" not in base64_like.rstrip("=")
        and re.fullmatch(r"[A-Za-z0-9+/=_-]{15,}", base64_like)
    ):
        connection_string = (
            "DefaultEndpointsProtocol=https;"
            f"AccountName={storage_account};"
            f"AccountKey={value};"
            "EndpointSuffix=core.windows.net"
        )
        return AzureCredential(
            storage_account=storage_account,
            connection_string=connection_string,
            account_key=value,
        )

    stripped = normalized_value.lstrip()
    if "\n" in normalized_value and not stripped.startswith(("{", "[")):
        colon_segments: list[str] = []
        for line in normalized_value.splitlines():
            clean_line = line.strip()
            if not clean_line or ":" not in clean_line:
                continue
            key, val = clean_line.split(":", 1)
            cleaned_val = val.strip()
            cleaned_val = cleaned_val.split("#", 1)[0].strip().strip("\"").strip("'")
            colon_segments.append(f"{key.strip()}={cleaned_val}")
        if colon_segments:
            try:
                return parse_credential(";".join(colon_segments), storage_account)
            except ValueError:
                pass

    try:
        decoded = json.loads(value)
    except json.JSONDecodeError:
        decoded = None
    if decoded is not None:
        def iter_string_candidates(obj: object) -> list[str]:
            stack: list[object] = [obj]
            strings: list[str] = []
            while stack:
                current = stack.pop()
                if isinstance(current, str):
                    normalized = current.strip()
                    if normalized:
                        strings.append(normalized)
                elif isinstance(current, dict):
                    for child in current.values():
                        stack.append(child)
                elif isinstance(current, list):
                    stack.extend(current)
            return strings

        seen: set[str] = set()
        for candidate in iter_string_candidates(decoded):
            if candidate == value or candidate in seen:
                continue
            seen.add(candidate)
            try:
                return parse_credential(candidate, storage_account)
            except ValueError:
                continue

    fingerprint = hashlib.sha256(normalized_value.encode("utf-8")).hexdigest()[:12]
    debug_hint = _heuristic_summary(normalized_value)
    preview = _redacted_preview(normalized_value)
    raise ValueError(
        "Unable to detect credential type. Provide an account key, SAS token, or connection string. "
        f"(len={len(normalized_value)}, fingerprint={fingerprint}, preview={preview}, {debug_hint})"
    )


def apply_secret(namespace: str, credential: AzureCredential) -> None:
    args = [
        "kubectl",
        "-n",
        namespace,
        "create",
        "secret",
        "generic",
        "cnpg-azure-backup",
        "--dry-run=client",
        "-o",
        "yaml",
        f"--from-literal=AZURE_STORAGE_ACCOUNT={credential.storage_account}",
        f"--from-literal=AZURE_CONNECTION_STRING={credential.connection_string}",
    ]
    if credential.account_key:
        args.append(f"--from-literal=AZURE_STORAGE_KEY={credential.account_key}")
    if credential.sas_token:
        args.append(f"--from-literal=AZURE_STORAGE_SAS_TOKEN={credential.sas_token}")
    proc = subprocess.run(args, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "Failed to render cnpg-azure-backup secret")
    apply = subprocess.run(["kubectl", "apply", "-f", "-"], input=proc.stdout, text=True, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if apply.returncode != 0:
        raise RuntimeError(apply.stderr.strip() or "kubectl apply failed")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--storage-account", required=True)
    parser.add_argument("--credential", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    credential = parse_credential(args.credential, args.storage_account)
    apply_secret(args.namespace, credential)
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
