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

usage() {
  cat <<'EOF'
Usage: configure_demo_hosts.sh [update|verify]

Commands:
  update  Resolve the ingress IP and update the GitOps patches (default).
  verify  Wait for Argo CD to reconcile the latest commit and smoke test the endpoints.

Environment variables:
  ARGOCD_APP_NAME     Argo CD application that manages the IAM stack (default: apps)
  ARGOCD_SYNC_TIMEOUT Timeout, in seconds, for argocd app wait (default: 900)
EOF
}

# Default configuration (can be overridden via environment variables).
NAMESPACE="${NAMESPACE_IAM:-${NAMESPACE:-iam}}"
PATCH_ROOT="${PATCH_ROOT:-k8s/apps}"
KEYCLOAK_HOST_PATCH_FILE="${KEYCLOAK_HOST_PATCH_FILE:-${PATCH_ROOT}/keycloak/hostname-patch.yaml}"
MIDPOINT_INGRESS_PATCH_FILE="${MIDPOINT_INGRESS_PATCH_FILE:-${PATCH_ROOT}/midpoint/ingress-host-patch.yaml}"
INGRESS_CLASS_NAME="${INGRESS_CLASS_NAME:-}"

require_cmd kubectl
require_cmd curl
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

check_endpoint() {
  local label="$1"
  shift
  local url status=1

  for url in "$@"; do
    [[ -n "${url}" ]] || continue
    log "Probing ${label} at ${url}"

    local headers_file body_file cookie_file http_code status_line curl_status
    headers_file=$(mktemp)
    body_file=$(mktemp)
    cookie_file=$(mktemp)

    # Capture headers and a small snippet of the body so we can surface
    # the HTTP status code (and any proxy errors) without fighting pipefail.
    if curl -sS --show-error --location --max-time 15 \
      --cookie "${cookie_file}" --cookie-jar "${cookie_file}" \
      --output "${body_file}" --dump-header "${headers_file}" \
      "${url}"; then
      status_line=$(head -n 1 "${headers_file}" | tr -d '\r\n')
      http_code=$(awk 'NR==1 {print $2}' "${headers_file}" | tr -d '\r\n')

      if [[ -n "${http_code}" && "${http_code}" =~ ^[0-9]+$ &&
            "${http_code}" -ge 200 && "${http_code}" -lt 400 ]]; then
        log "${label} responded via ${url}: ${status_line}"
        status=0
        rm -f "${headers_file}" "${body_file}" "${cookie_file}"
        break
      fi

      local error_snippet=""
      if [[ -s "${body_file}" ]]; then
        error_snippet=$(head -c 200 "${body_file}" | tr -d '\r')
      elif [[ -s "${headers_file}" ]]; then
        error_snippet=$(head -c 200 "${headers_file}" | tr -d '\r')
      fi

      if [[ -n "${error_snippet}" ]]; then
        log "${label} probe against ${url} returned HTTP ${http_code}; snippet: ${error_snippet}"
      else
        log "${label} probe against ${url} returned HTTP ${http_code}; will retry if attempts remain."
      fi
    else
      curl_status=$?
      local error_snippet=""
      if [[ -s "${body_file}" ]]; then
        error_snippet=$(head -c 200 "${body_file}" | tr -d '\r')
      elif [[ -s "${headers_file}" ]]; then
        error_snippet=$(head -c 200 "${headers_file}" | tr -d '\r')
      fi
      if [[ -n "${error_snippet}" ]]; then
        log "${label} probe against ${url} failed (curl exit ${curl_status}). Snippet: ${error_snippet}"
      else
        log "${label} probe against ${url} failed (curl exit ${curl_status})."
      fi
    fi

    rm -f "${headers_file}" "${body_file}" "${cookie_file}"
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

  # Probe the default root context first; fall back to the legacy /auth base
  # path if an older deployment still uses it.
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
      kubectl -n "${NAMESPACE}" get ingress -o wide || true
      exit 1
    fi

    log "Endpoints not ready yet; sleeping ${sleep_seconds}s before retry..."
    sleep "${sleep_seconds}"
  done
}

sync_gitops_app() {
  local app_name="${ARGOCD_APP_NAME:-apps}"
  local timeout="${ARGOCD_SYNC_TIMEOUT:-900}"

  require_cmd argocd

  log "Triggering Argo CD sync for application ${app_name}..."
  if ! argocd app sync "${app_name}" --core; then
    log "ERROR: Failed to start Argo CD sync for ${app_name}."
    argocd app get "${app_name}" --core || true
    exit 1
  fi

  log "Waiting for Argo CD application ${app_name} to become Synced and Healthy..."
  if ! argocd app wait "${app_name}" --sync --health --timeout "${timeout}" --core; then
    log "ERROR: Argo CD application ${app_name} did not become healthy in time."
    argocd app get "${app_name}" --core || true
    exit 1
  fi
  log "Argo CD application ${app_name} is synced and healthy."
}

update_mode() {
  wait_for_ingress_controller
  detect_ingress_class
  resolve_ingress_ip
  update_gitops_manifests

  log "✅ GitOps patches updated. Commit and push the changes to let Argo CD reconcile them."
  log "Keycloak host: ${KC_HOST}"
  log "midPoint host: ${MP_HOST}"
}

verify_mode() {
  wait_for_ingress_controller
  resolve_ingress_ip
  sync_gitops_app
  smoke_test

  log "✅ Verification complete."
  log "Keycloak URL: http://${KC_HOST}/"
  log "midPoint URL: http://${MP_HOST}/midpoint"
}

main() {
  local mode="update"

  if [[ $# -gt 0 ]]; then
    case "$1" in
      update|verify)
        mode="$1"
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        log "ERROR: Unknown command '$1'."
        usage
        exit 1
        ;;
    esac
  fi

  case "${mode}" in
    update)
      update_mode
      ;;
    verify)
      verify_mode
      ;;
    *)
      log "ERROR: Unsupported mode '${mode}'."
      exit 1
      ;;
  esac
}

main "$@"
