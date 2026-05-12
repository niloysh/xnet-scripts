#!/usr/bin/env bash
set -euo pipefail

# Use this script to open an interactive shell in the first pod whose name
# matches a keyword. If the pod has more than one container, the script will
# ask which container to use.

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

Open a shell in the first pod whose name matches <keyword>.

Options:
  -n, --namespace <namespace>   Kubernetes namespace (default: $(current_namespace))
  -h, --help                    Show this help message

Examples:
  $(basename "$0") amf
  $(basename "$0") upf --namespace demo
EOF
}

# Make sure kubectl is installed before doing any work.
require_prereqs() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: required command not found: kubectl" >&2
    exit 127
  fi
}

# Ask which container to use when the pod has more than one.
select_container() {
  echo "Select a container:"
  PS3="Container: "
  select CONTAINER in "${CONTAINERS[@]}"; do
    if [[ -n "${CONTAINER}" ]]; then
      break
    fi
  done
}

load_containers() {
  CONTAINERS=()
  while IFS= read -r container_name; do
    [[ -n "${container_name}" ]] && CONTAINERS+=("${container_name}")
  done < <(kubectl get pod "${POD}" -n "${NAMESPACE}" -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}')
}

# If you already selected a namespace in kubectl, the script uses it
# automatically. Otherwise it falls back to `default`.
NAMESPACE="$(current_namespace)"
POD_KEYWORD=""

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
        if [[ -z "${POD_KEYWORD}" ]]; then
          POD_KEYWORD="$1"
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
  kubectl get pods -n "${NAMESPACE}" --no-headers | grep "${POD_KEYWORD}" | awk 'NR==1{print $1}'
}

# Try `bash` first, then fall back to `sh` for smaller container images.
open_shell() {
  for shell_name in bash sh; do
    if kubectl exec "${POD}" -n "${NAMESPACE}" -c "${CONTAINER}" -- "${shell_name}" -c 'exit 0' >/dev/null 2>&1; then
      kubectl exec -it "${POD}" -n "${NAMESPACE}" -c "${CONTAINER}" -- "${shell_name}"
      exit 0
    fi
  done

  echo "No supported shell found in pod: ${POD}" >&2
  exit 1
}

parse_args "$@"

if [[ -z "${POD_KEYWORD}" ]]; then
  usage
  exit 1
fi

require_prereqs

POD="$(find_pod)"
if [[ -z "${POD}" ]]; then
  echo "No pod found with keyword: ${POD_KEYWORD} in namespace: ${NAMESPACE}" >&2
  exit 1
fi

load_containers
if [[ ${#CONTAINERS[@]} -eq 1 ]]; then
  CONTAINER="${CONTAINERS[0]}"
else
  select_container
fi

open_shell
