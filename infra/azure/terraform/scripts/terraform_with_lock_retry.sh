#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <terraform-subcommand> [args...]" >&2
  exit 2
fi

MAX_ATTEMPTS=${TERRAFORM_LOCK_MAX_ATTEMPTS:-5}
RETRY_BASE_SECONDS=${TERRAFORM_LOCK_RETRY_BASE_SECONDS:-15}
RETRY_MAX_SECONDS=${TERRAFORM_LOCK_RETRY_MAX_SECONDS:-300}

if ! [[ ${MAX_ATTEMPTS} =~ ^[0-9]+$ ]] || (( MAX_ATTEMPTS < 1 )); then
  echo "Invalid TERRAFORM_LOCK_MAX_ATTEMPTS value (${MAX_ATTEMPTS}); defaulting to 5." >&2
  MAX_ATTEMPTS=5
fi

if ! [[ ${RETRY_BASE_SECONDS} =~ ^[0-9]+$ ]] || (( RETRY_BASE_SECONDS < 1 )); then
  echo "Invalid TERRAFORM_LOCK_RETRY_BASE_SECONDS value (${RETRY_BASE_SECONDS}); defaulting to 15." >&2
  RETRY_BASE_SECONDS=15
fi

if ! [[ ${RETRY_MAX_SECONDS} =~ ^[0-9]+$ ]] || (( RETRY_MAX_SECONDS < 1 )); then
  echo "Invalid TERRAFORM_LOCK_RETRY_MAX_SECONDS value (${RETRY_MAX_SECONDS}); defaulting to 300." >&2
  RETRY_MAX_SECONDS=300
fi

LOCK_PATTERNS=(
  "Error acquiring the state lock"
  "state blob is already locked"
)

DEFAULT_FORCE_UNLOCK_AFTER_SECONDS=3600
FORCE_UNLOCK_AFTER_SECONDS_RAW="${TERRAFORM_LOCK_FORCE_UNLOCK_AFTER_SECONDS-}"
if [[ -z ${FORCE_UNLOCK_AFTER_SECONDS_RAW} ]]; then
  FORCE_UNLOCK_AFTER_SECONDS=${DEFAULT_FORCE_UNLOCK_AFTER_SECONDS}
else
  FORCE_UNLOCK_AFTER_SECONDS=${FORCE_UNLOCK_AFTER_SECONDS_RAW}
fi

if ! [[ ${FORCE_UNLOCK_AFTER_SECONDS} =~ ^[0-9]+$ ]]; then
  echo "Invalid TERRAFORM_LOCK_FORCE_UNLOCK_AFTER_SECONDS value (${FORCE_UNLOCK_AFTER_SECONDS}); defaulting to ${DEFAULT_FORCE_UNLOCK_AFTER_SECONDS}." >&2
  FORCE_UNLOCK_AFTER_SECONDS=${DEFAULT_FORCE_UNLOCK_AFTER_SECONDS}
fi

DEFAULT_FORCE_UNLOCK_AFTER_ATTEMPTS=3
FORCE_UNLOCK_AFTER_ATTEMPTS_RAW="${TERRAFORM_LOCK_FORCE_UNLOCK_AFTER_ATTEMPTS-}"
if [[ -z ${FORCE_UNLOCK_AFTER_ATTEMPTS_RAW} ]]; then
  FORCE_UNLOCK_AFTER_ATTEMPTS=${DEFAULT_FORCE_UNLOCK_AFTER_ATTEMPTS}
else
  FORCE_UNLOCK_AFTER_ATTEMPTS=${FORCE_UNLOCK_AFTER_ATTEMPTS_RAW}
fi

if ! [[ ${FORCE_UNLOCK_AFTER_ATTEMPTS} =~ ^[0-9]+$ ]]; then
  echo "Invalid TERRAFORM_LOCK_FORCE_UNLOCK_AFTER_ATTEMPTS value (${FORCE_UNLOCK_AFTER_ATTEMPTS}); defaulting to ${DEFAULT_FORCE_UNLOCK_AFTER_ATTEMPTS}." >&2
  FORCE_UNLOCK_AFTER_ATTEMPTS=${DEFAULT_FORCE_UNLOCK_AFTER_ATTEMPTS}
fi

attempt_force_unlock() {
  local lock_id="$1"

  if [[ -z ${lock_id} ]]; then
    echo "No lock ID provided for force unlock; skipping." >&2
    return 1
  fi

  set +e
  terraform force-unlock -force "${lock_id}"
  local status=$?
  set -e

  if (( status == 0 )); then
    echo "Successfully executed 'terraform force-unlock' for lock ${lock_id}."
  else
    echo "'terraform force-unlock' failed with exit code ${status}; continuing with retry strategy." >&2
  fi

  return ${status}
}

attempt=1
last_lock_id=""
consecutive_lock_attempts=0
while (( attempt <= MAX_ATTEMPTS )); do
  echo "--- Terraform attempt ${attempt}/${MAX_ATTEMPTS}: terraform $*"
  tmp_log=$(mktemp)
  set +e
  terraform "$@" 2>&1 | tee "${tmp_log}"
  exit_code=${PIPESTATUS[0]}
  set -e

  if (( exit_code == 0 )); then
    rm -f "${tmp_log}"
    echo "--- Terraform command completed successfully on attempt ${attempt}."
    exit 0
  fi

  if [[ ${attempt} -ge ${MAX_ATTEMPTS} ]]; then
    echo "Terraform failed after ${attempt} attempts; no retries remaining." >&2
    rm -f "${tmp_log}"
    exit ${exit_code}
  fi

  lock_detected=false
  lock_id=""
  lock_created=""
  for pattern in "${LOCK_PATTERNS[@]}"; do
    if grep -qi "${pattern}" "${tmp_log}"; then
      lock_detected=true
      break
    fi
  done

  if [[ ${lock_detected} == true ]]; then
    lock_id=$(awk '/ID:[[:space:]]/ { sub(/^.*ID:[[:space:]]*/, ""); print; exit }' "${tmp_log}" | tr -d '\r')
    lock_created=$(awk '/Created:[[:space:]]/ { sub(/^.*Created:[[:space:]]*/, ""); print; exit }' "${tmp_log}" | tr -d '\r')

    if [[ -n ${lock_id} ]]; then
      if [[ ${lock_id} == "${last_lock_id}" ]]; then
        consecutive_lock_attempts=$(( consecutive_lock_attempts + 1 ))
      else
        last_lock_id=${lock_id}
        consecutive_lock_attempts=1
      fi
    else
      consecutive_lock_attempts=0
      last_lock_id=""
    fi

    force_unlock_invoked=false
    lock_age_seconds=""

    if (( FORCE_UNLOCK_AFTER_SECONDS > 0 )) && [[ -n ${lock_id} ]] && [[ -n ${lock_created} ]]; then
      lock_created_s=""
      # Remove fractional seconds to improve parsing reliability (e.g., 2024-04-09 12:34:56).
      lock_created_trimmed=${lock_created%%.*}
      if lock_created_epoch=$(date -d "${lock_created}" +%s 2>/dev/null); then
        lock_created_s=${lock_created_epoch}
      elif lock_created_epoch=$(date -d "${lock_created_trimmed}" +%s 2>/dev/null); then
        lock_created_s=${lock_created_epoch}
      fi

      if [[ -n ${lock_created_s} ]]; then
        now_epoch=$(date +%s)
        lock_age_seconds=$(( now_epoch - lock_created_s ))
        if (( lock_age_seconds < 0 )); then
          lock_age_seconds=0
        fi

        if (( lock_age_seconds >= FORCE_UNLOCK_AFTER_SECONDS )); then
          echo "Terraform lock ${lock_id} is ${lock_age_seconds}s old (>= ${FORCE_UNLOCK_AFTER_SECONDS}s threshold); attempting force unlock."
          if attempt_force_unlock "${lock_id}"; then
            force_unlock_invoked=true
            consecutive_lock_attempts=0
            last_lock_id=""
          else
            force_unlock_invoked=true
          fi
        else
          echo "Terraform lock ${lock_id} is ${lock_age_seconds}s old (< ${FORCE_UNLOCK_AFTER_SECONDS}s threshold); skipping automatic force unlock."
        fi
      else
        echo "Unable to parse lock creation time (${lock_created}); skipping automatic force unlock." >&2
      fi
    fi

    if (( FORCE_UNLOCK_AFTER_ATTEMPTS > 0 )) && [[ -n ${lock_id} ]]; then
      if [[ ${force_unlock_invoked} != true ]]; then
        if (( consecutive_lock_attempts >= FORCE_UNLOCK_AFTER_ATTEMPTS )); then
          echo "Terraform lock ${lock_id} observed for ${consecutive_lock_attempts} consecutive attempt(s) (>= ${FORCE_UNLOCK_AFTER_ATTEMPTS}); attempting force unlock."
          if attempt_force_unlock "${lock_id}"; then
            force_unlock_invoked=true
            consecutive_lock_attempts=0
            last_lock_id=""
          else
            force_unlock_invoked=true
          fi
        elif (( FORCE_UNLOCK_AFTER_ATTEMPTS > 1 )); then
          remaining_attempts=$(( FORCE_UNLOCK_AFTER_ATTEMPTS - consecutive_lock_attempts ))
          echo "Terraform lock ${lock_id} observed for ${consecutive_lock_attempts} consecutive attempt(s); will force unlock after ${remaining_attempts} more attempt(s) if it persists."
        fi
      fi
    fi
  fi

  rm -f "${tmp_log}"

  if [[ ${lock_detected} != true ]]; then
    echo "Terraform failed with a non-lock error; aborting retries." >&2
    exit ${exit_code}
  fi

  wait_seconds=$(( RETRY_BASE_SECONDS * (2 ** (attempt - 1)) ))
  if (( wait_seconds > RETRY_MAX_SECONDS )); then
    wait_seconds=${RETRY_MAX_SECONDS}
  fi

  next_attempt=$(( attempt + 1 ))
  echo "Terraform state lock detected. Waiting ${wait_seconds}s before retry ${next_attempt}/${MAX_ATTEMPTS}."
  sleep ${wait_seconds}

  attempt=${next_attempt}
done

# Should never be reached due to loop exit conditions, but retain fallback for safety.
echo "Unexpected exit from retry loop." >&2
exit 1
