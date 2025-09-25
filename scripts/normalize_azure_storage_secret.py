#!/usr/bin/env python3
"""Normalize Azure Storage credentials into the cnpg-azure-backup secret."""
from __future__ import annotations

import argparse
import re
import subprocess
from dataclasses import dataclass


@dataclass
class AzureCredential:
    storage_account: str
    connection_string: str
    account_key: str | None = None
    sas_token: str | None = None


def parse_credential(raw: str, storage_account: str) -> AzureCredential:
    value = raw.strip()
    if not value:
        raise ValueError("Credential must not be empty")

    if ";" in value and "=" in value:
        parts: dict[str, tuple[str, str]] = {}
        for segment in value.split(";"):
            if not segment or "=" not in segment:
                continue
            key, val = segment.split("=", 1)
            parts[key.strip().lower()] = (key.strip(), val.strip())

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

    token = value.lstrip("?")
    if token.lower().startswith("sv=") and "sig=" in token:
        connection_string = (
            "DefaultEndpointsProtocol=https;"
            f"AccountName={storage_account};"
            f"BlobEndpoint=https://{storage_account}.blob.core.windows.net/;"
            f"SharedAccessSignature={token}"
        )
        return AzureCredential(storage_account=storage_account, connection_string=connection_string, sas_token=token)

    if re.fullmatch(r"[A-Za-z0-9+/=]{20,}" , value):
        connection_string = (
            "DefaultEndpointsProtocol=https;"
            f"AccountName={storage_account};"
            f"AccountKey={value};"
            "EndpointSuffix=core.windows.net"
        )
        return AzureCredential(storage_account=storage_account, connection_string=connection_string, account_key=value)

    raise ValueError("Unable to detect credential type. Provide an account key, SAS token, or connection string.")


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
