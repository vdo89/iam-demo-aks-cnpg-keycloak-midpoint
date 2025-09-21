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
KEYCLOAK_INGRESS_NAME="${KEYCLOAK_INGRESS_NAME:-rws-keycloak-public}"
MIDPOINT_INGRESS_NAME="${MIDPOINT_INGRESS_NAME:-midpoint}"
PATCH_ROOT="${PATCH_ROOT:-k8s/apps}"
KEYCLOAK_INGRESS_PATCH_FILE="${KEYCLOAK_INGRESS_PATCH_FILE:-${PATCH_ROOT}/keycloak/ingress-host-patch.yaml}"
MIDPOINT_INGRESS_PATCH_FILE="${MIDPOINT_INGRESS_PATCH_FILE:-${PATCH_ROOT}/midpoint/ingress-host-patch.yaml}"

require_cmd kubectl
require_cmd curl
require_cmd jq
require_cmd python3

apply_ingress() {
  local label="$1"
  local name="$2"
  local host="$3"
  local service_name="$4"
  local service_port="$5"

  log "Reconciling ${label} ingress (host ${host})..."
  cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "16m"
spec:
  ingressClassName: nginx
  rules:
    - host: ${host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${service_name}
                port:
                  number: ${service_port}
EOF
}

write_ingress_patch() {
  local label="$1"
  local patch_file="$2"
  local ingress_name="$3"
  local host="$4"

  log "Updating ${label} ingress patch at ${patch_file} with host ${host}..."
  cat <<EOF >"${patch_file}"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${ingress_name}
  namespace: ${NAMESPACE}
spec:
  rules:
    - host: ${host}
EOF
  log "${label} ingress patch updated. Commit and push this change so Argo CD reconciles the ingress host."
}

update_gitops_manifests() {
  write_ingress_patch "Keycloak" "${KEYCLOAK_INGRESS_PATCH_FILE}" "${KEYCLOAK_INGRESS_NAME}" "${KC_HOST}"
  write_ingress_patch "midPoint" "${MIDPOINT_INGRESS_PATCH_FILE}" "${MIDPOINT_INGRESS_NAME}" "${MP_HOST}"
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
  log "Waiting for ingress-nginx controller rollout..."
  kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=600s
}

wait_for_service_selector() {
  local service_name="$1"
  local attempts=30
  local sleep_seconds=10
  local svc_json selector

  for attempt in $(seq 1 "${attempts}"); do
    if ! svc_json=$(kubectl -n "${NAMESPACE}" get svc "${service_name}" -o json 2>/dev/null); then
      log "Service ${service_name} not ready yet (attempt ${attempt}/${attempts}); retrying in ${sleep_seconds}s..."
      sleep "${sleep_seconds}"
      continue
    fi

    selector=$(jq -r '
      .spec.selector // {} |
      to_entries |
      map(select(.value != null)) |
      map(.key + "=" + .value) |
      join(",")
    ' <<<"${svc_json}" | tr -d '\r\n')

    if [[ -n "${selector}" ]]; then
      echo "${selector}"
      return 0
    fi

    log "Service ${service_name} does not expose a selector yet (attempt ${attempt}/${attempts}); retrying..."
    sleep "${sleep_seconds}"
  done

  log "ERROR: Timed out waiting for service ${service_name} to publish a pod selector."
  kubectl -n "${NAMESPACE}" get svc "${service_name}" -o yaml || true
  exit 1
}

wait_for_keycloak() {
  local selector
  selector=$(wait_for_service_selector "${KEYCLOAK_SERVICE_NAME}")
  log "Keycloak service selector: ${selector}"

  log "Waiting for Keycloak pods to become Ready..."
  kubectl -n "${NAMESPACE}" wait --for=condition=ready pod -l "${selector}" --timeout=600s
}

wait_for_midpoint() {
  log "Waiting for midPoint deployment ${MIDPOINT_SERVICE_NAME} to become available..."
  kubectl -n "${NAMESPACE}" rollout status deploy/${MIDPOINT_SERVICE_NAME} --timeout=600s || true
  if ! kubectl -n "${NAMESPACE}" get svc "${MIDPOINT_SERVICE_NAME}" >/dev/null 2>&1; then
    log "WARNING: Service ${MIDPOINT_SERVICE_NAME} not found yet; continuing to ingress reconciliation."
  fi
}

apply_ingresses() {
  apply_ingress "Keycloak" "${KEYCLOAK_INGRESS_NAME}" "${KC_HOST}" "${KEYCLOAK_SERVICE_NAME}" "${KEYCLOAK_SERVICE_PORT}"
  apply_ingress "midPoint" "${MIDPOINT_INGRESS_NAME}" "${MP_HOST}" "${MIDPOINT_SERVICE_NAME}" "${MIDPOINT_SERVICE_PORT}"
  kubectl -n "${NAMESPACE}" get ingress "${MIDPOINT_INGRESS_NAME}" "${KEYCLOAK_INGRESS_NAME}" -o wide || true
}

check_endpoint() {
  local label="$1"
  shift
  local url status=1 response

  for url in "$@"; do
    [[ -n "${url}" ]] || continue
    log "Probing ${label} at ${url}"
    if response=$(curl -sS --fail --location --max-time 15 -o /dev/null -D - "${url}" 2>&1 | head -n 1); then
      log "${label} responded via ${url}: ${response}"
      status=0
      break
    else
      log "${label} probe against ${url} failed; will retry if attempts remain."
    fi
  done

  return "${status}"
}

smoke_test() {
  local attempts=6
  local sleep_seconds=20
  local i
  local prefix
  local keycloak_path
  local mp_path

  local -a keycloak_urls=("http://${KC_HOST}")
  local -a keycloak_paths=(
    "/realms/rws/.well-known/openid-configuration"
    "/realms/rws"
    "/realms/master/.well-known/openid-configuration"
    "/realms/master"
  )

  for prefix in "" "/auth"; do
    for keycloak_path in "${keycloak_paths[@]}"; do
      keycloak_urls+=("http://${KC_HOST}${prefix}${keycloak_path}")
    done
  done

  local -a midpoint_urls=()
  for mp_path in "/midpoint/" "/midpoint" ""; do
    midpoint_urls+=("http://${MP_HOST}${mp_path}")
  done

  for i in $(seq 1 "${attempts}"); do
    log "HTTP availability check ${i}/${attempts}..."
    if check_endpoint "Keycloak" "${keycloak_urls[@]}" && \
       check_endpoint "midPoint" "${midpoint_urls[@]}"; then
      log "Endpoints responded successfully."
      return 0
    fi

    if [[ "${i}" -eq "${attempts}" ]]; then
      log "ERROR: Keycloak or midPoint endpoint did not become reachable." >&2
      kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide || true
      kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o wide || true
      kubectl -n "${NAMESPACE}" get ingress "${MIDPOINT_INGRESS_NAME}" "${KEYCLOAK_INGRESS_NAME}" -o wide || true
      exit 1
    fi

    log "Endpoints not ready yet; sleeping ${sleep_seconds}s before retry..."
    sleep "${sleep_seconds}"
  done
}

main() {
  resolve_ingress_ip
  update_gitops_manifests
  wait_for_ingress_controller
  wait_for_keycloak
  wait_for_midpoint
  apply_ingresses
  smoke_test

  log "✅ Configuration complete."
  log "Keycloak URL: http://${KC_HOST}/auth"
  log "midPoint URL: http://${MP_HOST}/midpoint"
}

main "$@"
