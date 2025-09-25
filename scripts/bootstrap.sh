#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.1.7}"
ARGOCD_MANIFEST="github.com/argoproj/argo-cd//manifests/install?ref=${ARGOCD_VERSION}"

info() { printf '\n[bootstrap] %s\n' "$*"; }

for cmd in kubectl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[bootstrap] ERROR: required command '$cmd' is not available" >&2
    exit 1
  fi
done

info "Installing Argo CD ${ARGOCD_VERSION}"
kubectl apply -k "${ARGOCD_MANIFEST}" >/dev/null

info "Bootstrapping GitOps applications"
kubectl apply -k "${REPO_ROOT}/gitops/argocd"

info "Done"
