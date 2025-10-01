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
KEYCLOAK_OPERATOR_NAMESPACE=${KEYCLOAK_OPERATOR_NAMESPACE:-${KEYCLOAK_NAMESPACE}}
KEYCLOAK_NAME=${KEYCLOAK_NAME:-rws-keycloak}
KEYCLOAK_POD_SELECTOR=${KEYCLOAK_POD_SELECTOR:-app=keycloak}
KEYCLOAK_MGMT_PORT=${KEYCLOAK_MGMT_PORT:-9000}

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

keycloak_cr_missing=0

section "Keycloak custom resource status"
if ! kubectl get keycloak "${KEYCLOAK_NAME}" -n "${KEYCLOAK_NAMESPACE}" -o yaml; then
  keycloak_cr_missing=1
  warn "Keycloak custom resource ${KEYCLOAK_NAMESPACE}/${KEYCLOAK_NAME} not found; see docs/troubleshooting/keycloak-cr-missing.md"
  if command -v argocd >/dev/null 2>&1; then
    warn "Recreate it with: argocd app sync iam --resource k8s.keycloak.org/Keycloak:${KEYCLOAK_NAMESPACE}/${KEYCLOAK_NAME}"
  else
    warn "Trigger an Argo CD sync from the UI or reapply gitops/apps/iam/keycloak/keycloak.yaml to recreate the resource"
  fi
fi

section "Describe Keycloak custom resource"
if ! kubectl describe keycloak "${KEYCLOAK_NAME}" -n "${KEYCLOAK_NAMESPACE}"; then
  keycloak_cr_missing=1
  warn "Describe failed for ${KEYCLOAK_NAMESPACE}/${KEYCLOAK_NAME}; follow docs/troubleshooting/keycloak-cr-missing.md to recreate the resource"
fi

run_cmd "Keycloak pods" \
  kubectl get pods -n "${KEYCLOAK_NAMESPACE}" -l "${KEYCLOAK_POD_SELECTOR}" -o wide

run_cmd "Keycloak realm import custom resources" \
  kubectl get keycloakrealmimports.k8s.keycloak.org -n "${KEYCLOAK_NAMESPACE}" -o wide

run_cmd "Keycloak realm import jobs" \
  kubectl get jobs -n "${KEYCLOAK_NAMESPACE}" -l app=keycloak-realm-import --show-labels

mapfile -t keycloak_pods < <(
  kubectl get pods -n "${KEYCLOAK_NAMESPACE}" -l "${KEYCLOAK_POD_SELECTOR}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
)

log_contains() {
  local pod="$1"
  local pattern="$2"
  local scope="$3"

  local flags=("$pod" -n "${KEYCLOAK_NAMESPACE}" --tail=200)
  if [[ "${scope}" == "previous" ]]; then
    flags+=(--previous)
  fi

  if kubectl logs "${flags[@]}" 2>/dev/null | grep -Fq "$pattern"; then
    return 0
  fi
  return 1
}

diagnose_known_failures() {
  local pod="$1"

  if log_contains "$pod" "Unknown option: '--http-management-allowed-hosts'" current \
    || log_contains "$pod" "Unknown option: '--http-management-allowed-hosts'" previous; then
    warn "Detected deprecated CLI flag '--http-management-allowed-hosts' in pod ${pod}; remove it from gitops/apps/iam/keycloak/keycloak.yaml."
  fi

  if log_contains "$pod" "The '--optimized' flag was used for first ever server start" current \
    || log_contains "$pod" "The '--optimized' flag was used for first ever server start" previous; then
    warn "Pod ${pod} tried to start with '--optimized' before the initial build completed; ensure spec.startOptimized: false in gitops/apps/iam/keycloak/keycloak.yaml before the first boot."
  fi
}

if (( ${#keycloak_pods[@]} == 0 )); then
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

    run_cmd "Keycloak pod logs (${pod}, previous container)" \
      kubectl logs "${pod}" -n "${KEYCLOAK_NAMESPACE}" --tail=200 --previous

    for endpoint in /health /health/live /health/ready /health/started; do
      run_cmd "Keycloak health endpoint (${pod}, ${endpoint})" bash -c \
        "kubectl get --raw \"/api/v1/namespaces/${KEYCLOAK_NAMESPACE}/pods/${pod}:${KEYCLOAK_MGMT_PORT}/proxy${endpoint}\" | jq '.'"
    done

    diagnose_known_failures "${pod}"
  done
fi

if (( keycloak_cr_missing == 1 )); then
  warn "Keycloak diagnostics detected a missing custom resource; runbook: docs/troubleshooting/keycloak-cr-missing.md"
fi

run_cmd "Keycloak operator logs (last 15m)" \
  kubectl logs deployment/keycloak-operator -n "${KEYCLOAK_OPERATOR_NAMESPACE}" --since=15m
