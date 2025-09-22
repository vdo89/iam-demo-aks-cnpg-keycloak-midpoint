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

require_cmd kubectl
require_cmd jq
require_cmd curl

NAMESPACE="${NAMESPACE_IAM:-${NAMESPACE:-iam}}"
KEYCLOAK_CR_NAME="${KEYCLOAK_CR_NAME:-rws-keycloak}"
KEYCLOAK_SERVICE_NAME="${KEYCLOAK_SERVICE_NAME:-rws-keycloak-service}"
MIDPOINT_SERVICE_NAME="${MIDPOINT_SERVICE_NAME:-midpoint}"
MIDPOINT_INGRESS_NAME="${MIDPOINT_INGRESS_NAME:-midpoint}"
ARGO_APP_NAME="${ARGO_APP_NAME:-apps}"
ARGO_NAMESPACE="${ARGO_NAMESPACE:-argocd}"

KC_HOST="${KC_HOST:?KC_HOST environment variable must be set}"
MP_HOST="${MP_HOST:?MP_HOST environment variable must be set}"

trigger_argocd_refresh() {
  log "Requesting Argo CD refresh for application ${ARGO_APP_NAME}..."
  kubectl -n "${ARGO_NAMESPACE}" patch application "${ARGO_APP_NAME}" --type merge \
    --patch '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
}

wait_for_argocd_sync() {
  local attempts=30
  local sleep_seconds=10
  local app_json sync_status health_status revision

  for attempt in $(seq 1 "${attempts}"); do
    if ! app_json=$(kubectl -n "${ARGO_NAMESPACE}" get application "${ARGO_APP_NAME}" -o json 2>/dev/null); then
      log "Argo CD application ${ARGO_APP_NAME} not ready yet (attempt ${attempt}/${attempts}); retrying..."
      sleep "${sleep_seconds}"
      continue
    fi

    sync_status=$(jq -r '.status.sync.status // empty' <<<"${app_json}" | tr -d '\r\n')
    health_status=$(jq -r '.status.health.status // empty' <<<"${app_json}" | tr -d '\r\n')
    revision=$(jq -r '.status.sync.revision // empty' <<<"${app_json}" | tr -d '\r\n')

    if [[ "${sync_status}" == "Synced" && "${health_status}" == "Healthy" ]]; then
      if [[ -n "${revision}" ]]; then
        log "Argo CD application ${ARGO_APP_NAME} is Synced/Healthy at revision ${revision}."
      else
        log "Argo CD application ${ARGO_APP_NAME} is Synced/Healthy."
      fi
      return 0
    fi

    log "Argo CD application ${ARGO_APP_NAME} status: sync='${sync_status:-<empty>}' health='${health_status:-<empty>}' (attempt ${attempt}/${attempts}); waiting..."
    sleep "${sleep_seconds}"
  done

  log "ERROR: Argo CD application ${ARGO_APP_NAME} did not reach Synced/Healthy state in time."
  kubectl -n "${ARGO_NAMESPACE}" get application "${ARGO_APP_NAME}" -o yaml || true
  exit 1
}

wait_for_ingress_host() {
  local attempts=30
  local sleep_seconds=10
  local host

  for attempt in $(seq 1 "${attempts}"); do
    host=$(kubectl -n "${NAMESPACE}" get ingress "${MIDPOINT_INGRESS_NAME}" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)
    if [[ "${host}" == "${MP_HOST}" ]]; then
      log "midPoint ingress host updated to ${host}."
      return 0
    fi

    log "midPoint ingress host is '${host:-<unset>}' (attempt ${attempt}/${attempts}); waiting for GitOps reconcile..."
    sleep "${sleep_seconds}"
  done

  log "ERROR: midPoint ingress host did not update to ${MP_HOST}."
  kubectl -n "${NAMESPACE}" get ingress "${MIDPOINT_INGRESS_NAME}" -o yaml || true
  exit 1
}

wait_for_keycloak_hostname() {
  local attempts=30
  local sleep_seconds=10
  local host

  for attempt in $(seq 1 "${attempts}"); do
    host=$(kubectl -n "${NAMESPACE}" get keycloaks.k8s.keycloak.org "${KEYCLOAK_CR_NAME}" -o jsonpath='{.spec.hostname.hostname}' 2>/dev/null || true)
    if [[ "${host}" == "${KC_HOST}" ]]; then
      log "Keycloak hostname updated to ${host}."
      return 0
    fi

    log "Keycloak hostname is '${host:-<unset>}' (attempt ${attempt}/${attempts}); waiting for GitOps reconcile..."
    sleep "${sleep_seconds}"
  done

  log "ERROR: Keycloak hostname did not update to ${KC_HOST}."
  kubectl -n "${NAMESPACE}" get keycloaks.k8s.keycloak.org "${KEYCLOAK_CR_NAME}" -o yaml || true
  exit 1
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

wait_for_keycloak_ready() {
  local selector
  selector=$(wait_for_service_selector "${KEYCLOAK_SERVICE_NAME}")
  log "Keycloak service selector: ${selector}"

  log "Waiting for Keycloak pods to become Ready..."
  kubectl -n "${NAMESPACE}" wait --for=condition=ready pod -l "${selector}" --timeout=600s
}

wait_for_midpoint_ready() {
  log "Waiting for midPoint deployment ${MIDPOINT_SERVICE_NAME} to become available..."
  kubectl -n "${NAMESPACE}" rollout status deploy/"${MIDPOINT_SERVICE_NAME}" --timeout=600s || true
  if ! kubectl -n "${NAMESPACE}" get svc "${MIDPOINT_SERVICE_NAME}" >/dev/null 2>&1; then
    log "WARNING: Service ${MIDPOINT_SERVICE_NAME} not found yet; continuing to HTTP checks."
  fi
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

main() {
  trigger_argocd_refresh
  wait_for_argocd_sync
  wait_for_ingress_host
  wait_for_keycloak_hostname
  wait_for_keycloak_ready
  wait_for_midpoint_ready
  smoke_test

  log "✅ GitOps reconciliation complete."
  log "Keycloak URL: http://${KC_HOST}/"
  log "midPoint URL: http://${MP_HOST}/midpoint"
}

main "$@"
