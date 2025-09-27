#!/usr/bin/env bash
set -euo pipefail

error() {
  echo "[error] $*" >&2
}

warn() {
  echo "[warn] $*" >&2
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

KEYCLOAK_NAMESPACE=${KEYCLOAK_NAMESPACE:-iam}
KEYCLOAK_NAME=${KEYCLOAK_NAME:-rws-keycloak}
KEYCLOAK_POD_SELECTOR=${KEYCLOAK_POD_SELECTOR:-app=keycloak}
KEYCLOAK_MGMT_PORT=${KEYCLOAK_MGMT_PORT:-9000}
KEYCLOAK_OPERATOR_NAMESPACE=${KEYCLOAK_OPERATOR_NAMESPACE:-keycloak}
KEYCLOAK_OPERATOR_DEPLOYMENT=${KEYCLOAK_OPERATOR_DEPLOYMENT:-keycloak-operator}

if command -v argocd >/dev/null 2>&1; then
  run_cmd "Argo CD application summary (iam)" \
    argocd app get iam

  run_cmd "Argo CD application summary (keycloak-operator)" \
    argocd app get keycloak-operator

  run_cmd "Argo CD operation state (iam)" bash -c \
    "kubectl get application iam -n argocd -o json \
      | jq '.status.operationState | {phase, message, syncResult: .syncResult.resources[]? | select(.status == \"OutOfSync\")}'"
else
  warn "'argocd' CLI not found; skipping Argo CD application summaries"
  run_cmd "Argo CD operation state (iam)" bash -c \
    "kubectl get application iam -n argocd -o json \
      | jq '.status.operationState | {phase, message, syncResult: .syncResult.resources[]? | select(.status == \"OutOfSync\")}'"
fi

run_cmd "Check for Keycloak CRDs" \
  kubectl get crd keycloaks.k8s.keycloak.org keycloakrealmimports.k8s.keycloak.org

run_cmd "Keycloak custom resource status" \
  kubectl get keycloak "${KEYCLOAK_NAME}" -n "${KEYCLOAK_NAMESPACE}" -o yaml

run_cmd "Describe Keycloak custom resource" \
  kubectl describe keycloak "${KEYCLOAK_NAME}" -n "${KEYCLOAK_NAMESPACE}"

run_cmd "Keycloak pods" \
  kubectl get pods -n "${KEYCLOAK_NAMESPACE}" -l "${KEYCLOAK_POD_SELECTOR}" -o wide

mapfile -t keycloak_pods < <(
  kubectl get pods -n "${KEYCLOAK_NAMESPACE}" -l "${KEYCLOAK_POD_SELECTOR}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
)

if ((${#keycloak_pods[@]} == 0)); then
  warn "No Keycloak pods found with selector '${KEYCLOAK_POD_SELECTOR}' in namespace '${KEYCLOAK_NAMESPACE}'"

  run_cmd "Pods in namespace ${KEYCLOAK_NAMESPACE} (showing labels)" \
    kubectl get pods -n "${KEYCLOAK_NAMESPACE}" --show-labels

  run_cmd "Keycloak workloads in ${KEYCLOAK_NAMESPACE}" \
    kubectl get statefulsets,deployments -n "${KEYCLOAK_NAMESPACE}" \
      --selector="${KEYCLOAK_POD_SELECTOR}" --show-labels
else
  for pod in "${keycloak_pods[@]}"; do
    run_cmd "Describe Keycloak pod ${pod}" \
      kubectl describe pod "${pod}" -n "${KEYCLOAK_NAMESPACE}"

    run_cmd "Keycloak pod logs (${pod}, last 200 lines)" \
      kubectl logs "${pod}" -n "${KEYCLOAK_NAMESPACE}" --tail=200

    for endpoint in /health /health/live /health/ready /health/started; do
      run_cmd "Keycloak health endpoint (${pod}, ${endpoint})" bash -c \
        "kubectl get --raw \"/api/v1/namespaces/${KEYCLOAK_NAMESPACE}/pods/${pod}:${KEYCLOAK_MGMT_PORT}/proxy${endpoint}\" | jq '.'"
    done
  done
fi

if kubectl get deployment "${KEYCLOAK_OPERATOR_DEPLOYMENT}" -n "${KEYCLOAK_OPERATOR_NAMESPACE}" >/dev/null 2>&1; then
  run_cmd "Keycloak operator logs (last 15m)" \
    kubectl logs deployment/"${KEYCLOAK_OPERATOR_DEPLOYMENT}" -n "${KEYCLOAK_OPERATOR_NAMESPACE}" --since=15m
else
  warn "Keycloak operator deployment '${KEYCLOAK_OPERATOR_DEPLOYMENT}' not found in namespace '${KEYCLOAK_OPERATOR_NAMESPACE}'"
  run_cmd "List deployments in ${KEYCLOAK_OPERATOR_NAMESPACE}" \
    kubectl get deployments -n "${KEYCLOAK_OPERATOR_NAMESPACE}" --show-labels
fi
