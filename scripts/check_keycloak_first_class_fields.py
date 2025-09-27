#!/usr/bin/env python3
"""Validate that the Keycloak CR only uses strongly typed fields for first-class options."""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = REPO_ROOT / "gitops/apps/iam/keycloak/keycloak.yaml"

BANNED_ADDITIONAL_OPTIONS = {
    re.compile(r"^\s*-?\s*name:\s*db-url\s*$", re.MULTILINE): "--db-url",
    re.compile(r"^\s*-?\s*name:\s*hostname-strict\s*$", re.MULTILINE): "--hostname-strict",
    re.compile(r"^\s*-?\s*name:\s*hostname-strict-https\s*$", re.MULTILINE): "--hostname-strict-https",
    re.compile(r"^\s*-?\s*name:\s*features\s*$", re.MULTILINE): "--features",
}


def main() -> int:
    text = MANIFEST.read_text(encoding="utf-8")
    errors: list[str] = []

    for pattern, flag in BANNED_ADDITIONAL_OPTIONS.items():
        if pattern.search(text):
            errors.append(
                "Keycloak manifest must not configure "
                f"{flag} via additionalOptions (pattern '{pattern.pattern}')."
            )

    db_block_match = re.search(r"^  db:\n(?P<body>(?:^(?: {4}|\t).*(?:\n|$))*)", text, re.MULTILINE)
    if db_block_match:
        body = db_block_match.group("body")
        for line in body.splitlines():
            stripped = line.strip()
            if stripped.startswith("url:"):
                errors.append(
                    "Keycloak manifest must drive the database connection through typed host/port/database fields instead of spec.db.url."
                )
                break

        ssl_mode_match = re.search(r"^\s*sslMode:\s*(?P<value>\S+)", body, re.MULTILINE)
        if ssl_mode_match is None:
            errors.append("Keycloak manifest must set spec.db.sslMode to enforce TLS for database connections.")
        elif ssl_mode_match.group("value") != "require":
            errors.append(
                "Keycloak manifest must enforce TLS via spec.db.sslMode: require (found"
                f" '{ssl_mode_match.group('value')}')."
            )
    else:
        errors.append("Unable to locate spec.db block in Keycloak manifest; update the checker if the manifest moved.")

    if errors:
        for message in errors:
            print(f"ERROR: {message}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
