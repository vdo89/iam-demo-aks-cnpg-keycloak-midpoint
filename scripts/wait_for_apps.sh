#!/usr/bin/env bash
set -euo pipefail

IAM_NAMESPACE="${IAM_NAMESPACE:-}"

print_tracked_resources() {
  local resources_json="$1"
  jq -r '
    .[]
    | "  - \(.kind) \(.identifier): "
      + (if .health == "" then "Unknown" else .health end)
      + (if .message != "" then " (\(.message))" else "" end)
  ' <<<"${resources_json}"
}

print_ignored_resources() {
  local resources_json="$1"
  jq -r '.[] | "  - \(.kind) \(.identifier)"' <<<"${resources_json}"
}

dump_resource_yaml() {
  local kind="$1"
  local namespace="$2"
  local name="$3"
  local resource_name

  case "${kind}" in
    Keycloak)
      resource_name="keycloaks.k8s.keycloak.org"
      ;;
    KeycloakRealmImport)
      resource_name="keycloakrealmimports.k8s.keycloak.org"
      ;;
    *)
      resource_name="${kind,,}"
      ;;
  esac

  if [ -n "${namespace}" ]; then
    echo "---- kubectl get ${kind} ${namespace}/${name} -o yaml ----"
    kubectl -n "${namespace}" get "${resource_name}" "${name}" -o yaml || true
  else
    echo "---- kubectl get ${kind} ${name} -o yaml ----"
    kubectl get "${resource_name}" "${name}" -o yaml || true
  fi
}

log_container_tail() {
  local namespace="$1"
  local pod_name="$2"
  local container_name="$3"
  local container_scope="$4"
  local restart_count="$5"

  echo "---- Last 40 log lines from ${container_scope} container ${container_name} in pod ${namespace}/${pod_name} ----"
  kubectl -n "${namespace}" logs "${pod_name}" --container "${container_name}" --tail=40 || true

  if [[ "${restart_count}" =~ ^[0-9]+$ ]] && [ "${restart_count}" -gt 0 ]; then
    echo "---- Previous 40 log lines from ${container_scope} container ${container_name} in pod ${namespace}/${pod_name} ----"
    kubectl -n "${namespace}" logs "${pod_name}" --container "${container_name}" --previous --tail=40 || true
  fi
}

describe_pod_with_logs() {
  local namespace="$1"
  local pod_name="$2"

  if [ -z "${namespace}" ] || [ -z "${pod_name}" ]; then
    return
  fi

  echo "---- kubectl describe pod ${namespace}/${pod_name} ----"
  kubectl -n "${namespace}" describe pod "${pod_name}" || true

  local pod_json
  pod_json="$(kubectl -n "${namespace}" get pod "${pod_name}" -o json 2>/dev/null || true)"

  if [ -n "${pod_json}" ]; then
    local container_name restart_count
    local -a init_containers=()
    local -a app_containers=()

    mapfile -t init_containers < <(jq -r '.spec.initContainers[]?.name' <<<"${pod_json}")
    for container_name in "${init_containers[@]}"; do
      restart_count="$(jq -r --arg name "${container_name}" '.status.initContainerStatuses[]? | select(.name==$name) | .restartCount // ""' <<<"${pod_json}")"
      [[ "${restart_count}" =~ ^[0-9]+$ ]] || restart_count=0
      log_container_tail "${namespace}" "${pod_name}" "${container_name}" init "${restart_count}"
    done

    mapfile -t app_containers < <(jq -r '.spec.containers[]?.name' <<<"${pod_json}")
    for container_name in "${app_containers[@]}"; do
      restart_count="$(jq -r --arg name "${container_name}" '.status.containerStatuses[]? | select(.name==$name) | .restartCount // ""' <<<"${pod_json}")"
      [[ "${restart_count}" =~ ^[0-9]+$ ]] || restart_count=0
      log_container_tail "${namespace}" "${pod_name}" "${container_name}" app "${restart_count}"
    done
  else
    echo "---- Last 40 log lines from pod ${namespace}/${pod_name} ----"
    kubectl -n "${namespace}" logs "${pod_name}" --tail=40 || true
  fi
}

echo "Ensuring Argo CD application 'apps' has been created before monitoring status"
app_found=0
for attempt in $(seq 1 60); do
  if kubectl -n argocd get application apps >/dev/null 2>&1; then
    app_found=1
    echo "Argo CD application 'apps' detected"
    break
  fi
  echo "Application 'apps' not found yet (attempt ${attempt}/60)"
  sleep 10
done

if [ "${app_found}" -ne 1 ]; then
  echo "Timed out waiting for Argo CD application 'apps' to be created"
  kubectl -n argocd get applications || true
  exit 1
fi

echo "Waiting for Argo CD application 'apps' to report Synced/Healthy status"
diagnostics_dumped=0
last_tracked_resources_json="[]"
last_ignored_resources_json="[]"
ignored_resources_first_observed=0
ignored_diagnostics_dumped=0
last_crashloop_summary=""
apps_namespace="${IAM_NAMESPACE:-}"
for attempt in $(seq 1 90); do
  app_json=""
  if ! app_json=$(kubectl -n argocd get application apps -o json 2>/dev/null); then
    echo "Failed to fetch Argo CD application status (attempt ${attempt}/90); retrying in 10 seconds"
    sleep 10
    continue
  fi

  sync_status=$(jq -r '.status.sync.status // ""' <<<"${app_json}")
  health_status=$(jq -r '.status.health.status // ""' <<<"${app_json}")
  operation_phase=$(jq -r '.status.operationState.phase // ""' <<<"${app_json}")
  tracked_resources_json=$(jq -c '
    [
      .status.resources[]?
      | select((.status // "") != "Synced"
               or (((.health.status // "") != "") and (.health.status // "") != "Healthy"))
      | {
          kind: (.kind // "Unknown"),
          namespace: (.namespace // ""),
          name: (.name // ""),
          identifier: (if (.namespace // "") != "" then (.namespace + "/" + .name) else .name end),
          health: (.health.status // ""),
          message: (.health.message // "")
        }
    ]
  ' <<<"${app_json}")

  ignored_resources_json=$(jq -c '
    [
      .status.resources[]?
      | select((.status // "") == "Synced" and (.health.status // "") == "")
      | {
          kind: (.kind // "Unknown"),
          namespace: (.namespace // ""),
          name: (.name // ""),
          identifier: (if (.namespace // "") != "" then (.namespace + "/" + .name) else .name end)
        }
    ]
  ' <<<"${app_json}")

  echo "apps status: sync=${sync_status:-<unknown>} health=${health_status:-<unknown>} operation=${operation_phase:-<unknown>} (attempt ${attempt}/90)"

  if [[ "${tracked_resources_json}" != "${last_tracked_resources_json}" ]]; then
    if [[ "${tracked_resources_json}" != "[]" ]]; then
      echo "Resources still progressing or unhealthy:"
      print_tracked_resources "${tracked_resources_json}"
    elif [[ "${last_tracked_resources_json}" != "[]" ]]; then
      echo "All managed resources currently report Healthy."
    fi
    last_tracked_resources_json="${tracked_resources_json}"
  fi

  if [[ "${ignored_resources_json}" != "${last_ignored_resources_json}" ]]; then
    if [[ "${ignored_resources_json}" != "[]" ]]; then
      echo "Argo CD has not reported health status for the following synced resources yet; continuing to wait for explicit health information:"
      print_ignored_resources "${ignored_resources_json}"
      ignored_resources_first_observed=${attempt}
      ignored_diagnostics_dumped=0
    else
      ignored_resources_first_observed=0
      ignored_diagnostics_dumped=0
    fi
    last_ignored_resources_json="${ignored_resources_json}"
  fi

  if [[ "${ignored_resources_json}" != "[]" ]]; then
    if (( ignored_resources_first_observed == 0 )); then
      ignored_resources_first_observed=${attempt}
    fi

    observations=$((attempt - ignored_resources_first_observed + 1))
    if (( ignored_diagnostics_dumped == 0 && observations >= 6 )); then
      echo "Collecting current state for resources still missing Argo CD health information:"
      while IFS=$'\t' read -r ignored_kind ignored_namespace ignored_name ignored_identifier; do
        [[ -n "${ignored_kind}" ]] || continue
        dump_resource_yaml "${ignored_kind}" "${ignored_namespace}" "${ignored_name}"
      done < <(jq -r '.[] | [.kind, .namespace, .name, .identifier] | @tsv' <<<"${ignored_resources_json}")
      ignored_diagnostics_dumped=1
    fi
  fi

  if [ "${sync_status}" = "Synced" ] && [ "${health_status}" = "Healthy" ]; then
    echo "apps application is synced and healthy"
    kubectl -n argocd get application apps
    exit 0
  fi

  if [ "${operation_phase}" = "Failed" ] && [ "${diagnostics_dumped}" -eq 0 ]; then
    echo "Latest Argo CD sync operation failed. Dumping application manifest for troubleshooting."
    kubectl -n argocd get application apps -o yaml || true
    diagnostics_dumped=1
  fi

  if [ "${health_status}" = "Degraded" ] && [ "${diagnostics_dumped}" -eq 0 ]; then
    echo "apps application health is Degraded. Dumping application manifest for troubleshooting."
    kubectl -n argocd get application apps -o yaml || true

    if [[ "${tracked_resources_json}" != "[]" ]]; then
      echo "Collecting detailed status for non-healthy resources reported by Argo CD:"
      while IFS=$'\t' read -r res_kind res_namespace res_name res_identifier res_health res_message; do
        [[ -n "${res_kind}" ]] || continue

        if [ -n "${res_message}" ]; then
          echo "Resource ${res_kind} ${res_identifier} reported ${res_health}: ${res_message}"
        else
          echo "Resource ${res_kind} ${res_identifier} reported ${res_health}"
        fi

        case "${res_kind}" in
          Deployment)
            if [ -n "${res_namespace}" ]; then
              echo "---- kubectl describe deployment ${res_namespace}/${res_name} ----"
              kubectl -n "${res_namespace}" describe deployment "${res_name}" || true
            fi
            ;;
          StatefulSet)
            if [ -n "${res_namespace}" ]; then
              echo "---- kubectl describe statefulset ${res_namespace}/${res_name} ----"
              kubectl -n "${res_namespace}" describe statefulset "${res_name}" || true
            fi
            ;;
          Pod)
            describe_pod_with_logs "${res_namespace}" "${res_name}"
            ;;
          *)
            dump_resource_yaml "${res_kind}" "${res_namespace}" "${res_name}"
            ;;
        esac
      done < <(jq -r '.[] | [.kind, .namespace, .name, .identifier, (if .health == "" then "Unknown" else .health end), .message] | @tsv' <<<"${tracked_resources_json}")
    fi

    if kubectl get ns "${apps_namespace}" >/dev/null 2>&1; then
      echo "Pods in namespace ${apps_namespace}:"
      kubectl -n "${apps_namespace}" get pods -o wide || true
      echo "Recent events in namespace ${apps_namespace}:"
      kubectl -n "${apps_namespace}" get events --sort-by=.metadata.creationTimestamp | tail -n 50 || true
    fi

    diagnostics_dumped=1
  fi

  if [ -n "${apps_namespace}" ] && kubectl get ns "${apps_namespace}" >/dev/null 2>&1; then
    pods_json="$(kubectl -n "${apps_namespace}" get pods -o json 2>/dev/null || true)"
    if [ -n "${pods_json}" ]; then
      crashloop_json="$(jq -c '
        def crash_state($state):
          if ($state | type) != "object" then
            {reason: "", message: "", phase: ""}
          elif $state.waiting? then
            {reason: ($state.waiting.reason // ""), message: ($state.waiting.message // ""), phase: "waiting"}
          elif $state.terminated? then
            {reason: ($state.terminated.reason // ""), message: ($state.terminated.message // ""), phase: "terminated"}
          else
            {reason: "", message: "", phase: ""}
          end;

        def reason_matches($reason):
          ($reason != "") and ((["CrashLoopBackOff","Error","ImagePullBackOff","CreateContainerConfigError","ContainerCannotRun"] | index($reason)) != null);

        [
          .items[] as $pod |
          (
            (
              [($pod.status.initContainerStatuses // [])[] |
                (crash_state(.state // {}) as $state |
                 select(reason_matches($state.reason)) |
                 [
                   $pod.metadata.name,
                   "init",
                   .name,
                   (.restartCount // 0),
                   $state.reason,
                   $state.message
                 ])]
            ) +
            (
              [($pod.status.containerStatuses // [])[] |
                (crash_state(.state // {}) as $state |
                 select(reason_matches($state.reason)) |
                 [
                   $pod.metadata.name,
                   "app",
                   .name,
                   (.restartCount // 0),
                   $state.reason,
                   $state.message
                 ])]
            )
          )
        ] | add // []
      ' <<<"${pods_json}" 2>/dev/null || true)"

      if [ -n "${crashloop_json}" ] && [ "${crashloop_json}" != "[]" ]; then
        crashloop_signature="$(jq -r '.[] | [.[0], .[1], .[2], .[4]] | @tsv' <<<"${crashloop_json}" | sort -u)"
        if [ "${crashloop_signature}" != "${last_crashloop_summary}" ]; then
          echo "Detected pods with CrashLoopBackOff or related failure states in namespace ${apps_namespace}; collecting diagnostics."
          crashloop_data="$(jq -r '.[] | @tsv' <<<"${crashloop_json}")"
          declare -A described_pods=()
          while IFS=$'\t' read -r pod_name container_scope container_name restart_count failure_reason failure_message; do
            [ -n "${pod_name}" ] || continue
            if [ -z "${described_pods["${pod_name}"]+x}" ]; then
              echo "---- kubectl describe pod ${apps_namespace}/${pod_name} ----"
              kubectl -n "${apps_namespace}" describe pod "${pod_name}" || true
              described_pods["${pod_name}"]=1
            fi
            if [ -n "${failure_message}" ]; then
              echo "Pod ${pod_name} ${container_scope} container ${container_name} is in state ${failure_reason}: ${failure_message}"
            else
              echo "Pod ${pod_name} ${container_scope} container ${container_name} is in state ${failure_reason}"
            fi
            log_container_tail "${apps_namespace}" "${pod_name}" "${container_name}" "${container_scope}" "${restart_count}"
          done <<<"${crashloop_data}"
          last_crashloop_summary="${crashloop_signature}"
        fi
      else
        last_crashloop_summary=""
      fi
    fi
  fi

  sleep 10
done

echo "Timed out waiting for Argo CD application 'apps' to become synced and healthy"
kubectl -n argocd get application apps -o yaml || true
if kubectl get ns "${apps_namespace}" >/dev/null 2>&1; then
  echo "Pods in namespace ${apps_namespace}:"
  kubectl -n "${apps_namespace}" get pods -o wide || true
  echo "Recent events in namespace ${apps_namespace}:"
  kubectl -n "${apps_namespace}" get events --sort-by=.metadata.creationTimestamp | tail -n 50 || true
fi
exit 1
