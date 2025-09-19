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

attempt=1
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
  for pattern in "${LOCK_PATTERNS[@]}"; do
    if grep -qi "${pattern}" "${tmp_log}"; then
      lock_detected=true
      break
    fi
  done

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
