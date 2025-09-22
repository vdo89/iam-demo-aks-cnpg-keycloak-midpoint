#!/usr/bin/env bash
set -euo pipefail

log() {
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  echo "[${timestamp}] $*"
}

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    log "ERROR: Required command '$name' is not available."
    exit 1
  fi
}

# Default configuration (can be overridden via environment variables).
NAMESPACE="${NAMESPACE_IAM:-${NAMESPACE:-iam}}"
KEYCLOAK_SERVICE_NAME="${KEYCLOAK_SERVICE_NAME:-rws-keycloak-service}"
KEYCLOAK_SERVICE_PORT="${KEYCLOAK_SERVICE_PORT:-8080}"
MIDPOINT_SERVICE_NAME="${MIDPOINT_SERVICE_NAME:-midpoint}"
MIDPOINT_SERVICE_PORT="${MIDPOINT_SERVICE_PORT:-8080}"
MIDPOINT_INGRESS_NAME="${MIDPOINT_INGRESS_NAME:-midpoint}"
PATCH_ROOT="${PATCH_ROOT:-k8s/apps}"
KEYCLOAK_CR_NAME="${KEYCLOAK_CR_NAME:-rws-keycloak}"
KEYCLOAK_HOST_PATCH_FILE="${KEYCLOAK_HOST_PATCH_FILE:-${PATCH_ROOT}/keycloak/hostname-patch.yaml}"
MIDPOINT_INGRESS_PATCH_FILE="${MIDPOINT_INGRESS_PATCH_FILE:-${PATCH_ROOT}/midpoint/ingress-host-patch.yaml}"
INGRESS_CLASS_NAME="${INGRESS_CLASS_NAME:-}"

require_cmd kubectl
require_cmd jq
require_cmd python3

write_ingress_patch() {
  local label="$1"
  local patch_file="$2"
  local host="$3"

  log "Updating ${label} ingress patch at ${patch_file} with host ${host}..."
  cat <<EOF >"${patch_file}"
- op: add
  path: /spec/ingressClassName
  value: ${INGRESS_CLASS_NAME}
- op: add
  path: /spec/rules/0/host
  value: ${host}
EOF
  log "${label} ingress patch updated. Commit and push this change so Argo CD reconciles the ingress host."
}

write_keycloak_hostname_patch() {
  local patch_file="$1"
  local host="$2"

  log "Updating Keycloak hostname patch at ${patch_file} with host ${host}..."
  cat <<EOF >"${patch_file}"
- op: add
  path: /spec/hostname/hostname
  value: ${host}
EOF
  log "Keycloak hostname patch updated. Commit and push this change so Argo CD reconciles the ingress host."
}

# Ensure the GitOps manifests target the ingress-nginx controller that actually
# exists in the cluster. Some environments publish the class as "nginx", others
# as "ingress-nginx" (or mark an internal/external variant as default). Auto-
# detecting the class prevents the "IngressClass <name> not found" events the
# user reported when the script or manifests point at the wrong name.
detect_ingress_class() {
  local json=""
  local detected=""

  if [[ -n "${INGRESS_CLASS_NAME}" ]]; then
    if kubectl get ingressclass "${INGRESS_CLASS_NAME}" >/dev/null 2>&1; then
      log "Using ingress class ${INGRESS_CLASS_NAME} from INGRESS_CLASS_NAME."
      return
    fi

    log "ERROR: IngressClass ${INGRESS_CLASS_NAME} not found in the cluster."
    kubectl get ingressclass || true
    exit 1
  fi

  log "Auto-detecting ingress-nginx IngressClass..."
  if ! json=$(kubectl get ingressclass -o json 2>/dev/null); then
    log "ERROR: Failed to list IngressClass resources."
    exit 1
  fi

  detected=$(jq -r '
    .items
    | map(select(.spec.controller == "k8s.io/ingress-nginx"))
    | (map(select((.metadata.annotations["ingressclass.kubernetes.io/is-default-class"] // "") == "true"))[0]?.metadata.name
       // .[0]?.metadata.name
       // empty)
  ' <<<"${json}" | tr -d '\r\n')

  if [[ -z "${detected}" ]]; then
    log "ERROR: Could not find an IngressClass managed by ingress-nginx."
    kubectl get ingressclass || true
    exit 1
  fi

  INGRESS_CLASS_NAME="${detected}"
  log "Detected ingress class: ${INGRESS_CLASS_NAME}"
}

update_gitops_manifests() {
  write_keycloak_hostname_patch "${KEYCLOAK_HOST_PATCH_FILE}" "${KC_HOST}"
  write_ingress_patch "midPoint" "${MIDPOINT_INGRESS_PATCH_FILE}" "${MP_HOST}"
}

resolve_ingress_ip() {
  local attempt max_attempts sleep_seconds
  local ip=""
  local hostname=""
  max_attempts=20
  sleep_seconds=10

  log "Resolving external IP for ingress-nginx-controller..."
  for attempt in $(seq 1 "${max_attempts}"); do
    ip=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -n "${ip}" ]]; then
      break
    fi

    hostname=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    if [[ -n "${hostname}" ]]; then
      ip=$(python3 -c 'import socket, sys
try:
    print(socket.gethostbyname(sys.argv[1]))
except Exception:
    pass
' "${hostname}" 2>/dev/null | tail -n1)
      if [[ -n "${ip}" ]]; then
        break
      fi
    fi

    log "Attempt ${attempt}/${max_attempts}: external IP not published yet; retrying in ${sleep_seconds}s..."
    sleep "${sleep_seconds}"
  done

  if [[ -z "${ip}" ]]; then
    log "ERROR: Could not determine external IP for ingress-nginx-controller."
    kubectl -n ingress-nginx get svc ingress-nginx-controller -o yaml || true
    exit 1
  fi

  EXTERNAL_IP="${ip}"
  KC_HOST="kc.${EXTERNAL_IP}.nip.io"
  MP_HOST="mp.${EXTERNAL_IP}.nip.io"

  log "Resolved ingress external IP: ${EXTERNAL_IP}"
  log "Keycloak host will be ${KC_HOST}"
  log "midPoint host will be ${MP_HOST}"

  if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
      echo "EXTERNAL_IP=${EXTERNAL_IP}"
      echo "KC_HOST=${KC_HOST}"
      echo "MP_HOST=${MP_HOST}"
    } >>"${GITHUB_ENV}"
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "keycloak_url=http://${KC_HOST}"
      echo "midpoint_url=http://${MP_HOST}/midpoint"
    } >>"${GITHUB_OUTPUT}"
  fi
}

wait_for_ingress_controller() {
  local attempts=30
  local sleep_seconds=10
  local attempt

  log "Waiting for ingress-nginx controller rollout..."

  for attempt in $(seq 1 "${attempts}"); do
    if kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1; then
      break
    fi

    log "ingress-nginx controller deployment not created yet (attempt ${attempt}/${attempts}); retrying in ${sleep_seconds}s..."
    sleep "${sleep_seconds}"
  done

  if ! kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1; then
    log "ERROR: ingress-nginx controller deployment not found."
    kubectl -n ingress-nginx get deploy || true
    exit 1
  fi

  kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=600s
}


main() {
  wait_for_ingress_controller
  detect_ingress_class
  resolve_ingress_ip
  update_gitops_manifests

  log "✅ Generated GitOps patches for ingress hosts."
  log "Commit and push ${KEYCLOAK_HOST_PATCH_FILE} and ${MIDPOINT_INGRESS_PATCH_FILE} so Argo CD reconciles the new hostnames."
  log "Keycloak host: http://${KC_HOST}/"
  log "midPoint host: http://${MP_HOST}/midpoint"
}

main "$@"
