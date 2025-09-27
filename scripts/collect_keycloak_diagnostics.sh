#!/usr/bin/env bash
set -euo pipefail

error() {
  echo "[error] $*" >&2
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    error "Required command '$cmd' not found in PATH"
    exit 1
  fi
}

section() {
  local title="$1"
  printf '\n===== %s =====\n' "$title"
}

run_cmd() {
  local description="$1"
  shift

  section "$description"
  if "$@"; then
    return 0
  fi

  local status=$?
  error "Command failed with status $status: $*"
  return 0
}

require_cmd kubectl
require_cmd jq

if command -v argocd >/dev/null 2>&1; then
  run_cmd "Argo CD application summary (iam)" \
    argocd app get iam

  run_cmd "Argo CD application summary (keycloak-operator)" \
    argocd app get keycloak-operator

  run_cmd "Argo CD operation state (iam)" bash -c \
    "kubectl get application iam -n argocd -o json \
      | jq '.status.operationState | {phase, message, syncResult: .syncResult.resources[]? | select(.status == \"OutOfSync\")}'"
else
  error "'argocd' CLI not found; skipping Argo CD application summaries"
  run_cmd "Argo CD operation state (iam)" bash -c \
    "kubectl get application iam -n argocd -o json \
      | jq '.status.operationState | {phase, message, syncResult: .syncResult.resources[]? | select(.status == \"OutOfSync\")}'"
fi

run_cmd "Check for Keycloak CRDs" \
  kubectl get crd keycloaks.k8s.keycloak.org keycloakrealmimports.k8s.keycloak.org

run_cmd "Keycloak operator logs (last 15m)" \
  kubectl logs deployment/keycloak-operator -n keycloak --since=15m
