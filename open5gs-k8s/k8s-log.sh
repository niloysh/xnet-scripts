#!/usr/bin/env bash
set -euo pipefail

# Use this script to follow logs from the first pod whose name matches a
# keyword. If the pod has more than one container, the script will ask which
# container to use.

current_namespace() {
  local ns
  ns="$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || true)"
  if [[ -n "${ns}" ]]; then
    printf '%s\n' "${ns}"
  else
    printf 'default\n'
  fi
}

# Show the supported commands and options.
usage() {
  cat <<EOF
Usage: $(basename "$0") <keyword> [options]

Follow logs from the first pod whose name matches <keyword>.

Options:
  -n, --namespace <namespace>   Kubernetes namespace (default: $(current_namespace))
  -h, --help                    Show this help message

Examples:
  $(basename "$0") amf
  $(basename "$0") upf -n demo
EOF
}

# Make sure kubectl is installed before doing any work.
require_prereqs() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: required command not found: kubectl" >&2
    exit 127
  fi
}

# If you already selected a namespace in kubectl, the script uses it
# automatically. Otherwise it falls back to `default`.
NAMESPACE="$(current_namespace)"
KEYWORD=""

# Parse the options that come after the keyword.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace)
        NAMESPACE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        if [[ -z "${KEYWORD}" ]]; then
          KEYWORD="$1"
          shift
        else
          echo "ERROR: unknown argument: $1" >&2
          usage >&2
          exit 1
        fi
        ;;
    esac
  done
}

# Find the first pod whose name contains the provided keyword.
find_pod() {
  kubectl get pods -n "${NAMESPACE}" --no-headers | grep "${KEYWORD}" | head -1 | awk '{print $1}'
}

# Ask which container to use when the pod has more than one.
select_container() {
  echo "Select container:"
  PS3="Container: "
  select container in "${containers[@]}"; do
    if [[ -n "${container}" ]]; then
      break
    fi
  done
}

load_containers() {
  containers=()
  while IFS= read -r container_name; do
    [[ -n "${container_name}" ]] && containers+=("${container_name}")
  done < <(kubectl get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}')
}

parse_args "$@"

if [[ -z "${KEYWORD}" ]]; then
  usage
  exit 1
fi

require_prereqs

pod="$(find_pod)"
if [[ -z "${pod}" ]]; then
  echo "No pods found for keyword: ${KEYWORD} in namespace: ${NAMESPACE}" >&2
  exit 1
fi

load_containers
if [[ ${#containers[@]} -eq 1 ]]; then
  container="${containers[0]}"
else
  select_container
fi

kubectl logs -f "${pod}" -n "${NAMESPACE}" -c "${container}"
