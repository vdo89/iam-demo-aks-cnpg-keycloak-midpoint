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

MIDPOINT_NAMESPACE=${MIDPOINT_NAMESPACE:-iam}
MIDPOINT_APP_NAME=${MIDPOINT_APP_NAME:-iam}
MIDPOINT_POD_SELECTOR=${MIDPOINT_POD_SELECTOR:-app=midpoint}
MIDPOINT_SEEDER_JOB=${MIDPOINT_SEEDER_JOB:-midpoint-seeder}
CNPG_CLUSTER_NAME=${CNPG_CLUSTER_NAME:-iam-db}

if command -v argocd >/dev/null 2>&1; then
  run_cmd "Argo CD application summary (${MIDPOINT_APP_NAME})" \
    argocd app get "${MIDPOINT_APP_NAME}"
else
  warn "'argocd' CLI not found; skipping Argo CD application summary"
fi

run_cmd "Argo CD operation state (${MIDPOINT_APP_NAME})" bash -c \
  "kubectl get application ${MIDPOINT_APP_NAME} -n argocd -o json \
    | jq '.status.operationState | {phase, message, syncResult: .syncResult.resources[]? | select(.status == \"OutOfSync\")}'"

run_cmd "midPoint deployment" \
  kubectl get deployment/midpoint -n "${MIDPOINT_NAMESPACE}" -o yaml

run_cmd "midPoint seeder job" \
  kubectl get job "${MIDPOINT_SEEDER_JOB}" -n "${MIDPOINT_NAMESPACE}" -o yaml

run_cmd "midPoint seeder job pods" \
  kubectl get pods -n "${MIDPOINT_NAMESPACE}" --selector="job-name=${MIDPOINT_SEEDER_JOB}" -o wide

if kubectl get job "${MIDPOINT_SEEDER_JOB}" -n "${MIDPOINT_NAMESPACE}" >/dev/null 2>&1; then
  run_cmd "midPoint seeder job logs" \
    kubectl logs job/"${MIDPOINT_SEEDER_JOB}" -n "${MIDPOINT_NAMESPACE}" --tail=200
fi

run_cmd "midPoint pods" \
  kubectl get pods -n "${MIDPOINT_NAMESPACE}" -l "${MIDPOINT_POD_SELECTOR}" -o wide

mapfile -t midpoint_pods < <(
  kubectl get pods -n "${MIDPOINT_NAMESPACE}" -l "${MIDPOINT_POD_SELECTOR}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
)

print_container_logs() {
  local pod="$1"
  local container="$2"
  local type="$3"

  run_cmd "${type} logs for pod ${pod} container ${container}" \
    kubectl logs "${pod}" -n "${MIDPOINT_NAMESPACE}" -c "${container}" --tail=200
}

if ((${#midpoint_pods[@]} == 0)); then
  warn "No midPoint pods found with selector '${MIDPOINT_POD_SELECTOR}' in namespace '${MIDPOINT_NAMESPACE}'"

  run_cmd "Pods in namespace ${MIDPOINT_NAMESPACE} (showing labels)" \
    kubectl get pods -n "${MIDPOINT_NAMESPACE}" --show-labels
else
  for pod in "${midpoint_pods[@]}"; do
    run_cmd "Describe midPoint pod ${pod}" \
      kubectl describe pod "${pod}" -n "${MIDPOINT_NAMESPACE}"

    mapfile -t init_containers < <(
      kubectl get pod "${pod}" -n "${MIDPOINT_NAMESPACE}" \
        -o jsonpath='{range .spec.initContainers[*]}{.name}{"\n"}{end}' 2>/dev/null || true
    )

    for container in "${init_containers[@]}"; do
      print_container_logs "${pod}" "${container}" "Init"
    done

    mapfile -t app_containers < <(
      kubectl get pod "${pod}" -n "${MIDPOINT_NAMESPACE}" \
        -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null || true
    )

    for container in "${app_containers[@]}"; do
      print_container_logs "${pod}" "${container}" "Container"
    done
  done
fi

run_cmd "CloudNativePG cluster status" \
  kubectl get cluster "${CNPG_CLUSTER_NAME}" -n "${MIDPOINT_NAMESPACE}" -o yaml

run_cmd "CloudNativePG databases" \
  kubectl get databases.postgresql.cnpg.io -n "${MIDPOINT_NAMESPACE}" -o wide

run_cmd "midPoint database resource" \
  kubectl get database/midpoint -n "${MIDPOINT_NAMESPACE}" -o yaml

run_cmd "CNPG pods" \
  kubectl get pods -n "${MIDPOINT_NAMESPACE}" -l "cnpg.io/cluster=${CNPG_CLUSTER_NAME}" -o wide

warn "Review the seeder job logs for repeated HTTP 401/403 responses; these now fail fast when credentials are wrong."
