#!/usr/bin/env bash
set -euo pipefail

ARGO_CD_VERSION="v2.11.3"
MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_CD_VERSION}/manifests/install.yaml"
ROOT_KUSTOMIZATION="clusters/aks/argocd"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required" >&2
  exit 1
fi

kubectl apply -f "${MANIFEST_URL}"
kubectl apply -k "${ROOT_KUSTOMIZATION}"
