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
PARAMS_ENV_FILE="${PARAMS_ENV_FILE:-k8s/apps/params.env}"
INGRESS_CLASS_NAME="${INGRESS_CLASS_NAME:-}"

require_cmd kubectl
require_cmd jq
require_cmd python3

write_ingress_params() {
  local file="$1"
  local ingress_class="$2"
  local keycloak_host="$3"
  local midpoint_host="$4"

  log "Writing ingress parameters to ${file}..."
  cat <<EOF >"${file}"
# Ingress parameters for the IAM demo environment.
# Updated by scripts/configure_demo_hosts.sh.
ingressClass=${ingress_class}
keycloakHost=${keycloak_host}
midpointHost=${midpoint_host}
EOF
  log "Ingress parameters updated. Commit and push this change so Argo CD reconciles the new hosts."
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
  if [[ -z "${INGRESS_CLASS_NAME}" ]]; then
    log "ERROR: Ingress class name is not set."
    exit 1
  fi

  write_ingress_params "${PARAMS_ENV_FILE}" "${INGRESS_CLASS_NAME}" "${KC_HOST}" "${MP_HOST}"
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
  log "✅ GitOps parameters updated in ${PARAMS_ENV_FILE}."
  log "Commit and push the change so Argo CD reconciles the ingress configuration."
  log "Keycloak host: ${KC_HOST}"
  log "midPoint host: ${MP_HOST}"
}

main "$@"
