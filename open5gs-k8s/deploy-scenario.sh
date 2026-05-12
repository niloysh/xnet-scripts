#!/usr/bin/env bash
set -euo pipefail

# Use this script to bring up or tear down a complete xNet scenario. The
# overall flow is:
# 1. install the toolbox chart
# 2. ask the toolbox pod to generate scenario-specific values files
# 3. install the core chart
# 4. seed subscribers
# 5. optionally install UERANSIM

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

current_namespace() {
  local ns
  ns="$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || true)"
  if [[ -n "${ns}" ]]; then
    printf '%s\n' "${ns}"
  else
    printf 'default\n'
  fi
}

# --- Scenario defaults ---
# If you already selected a namespace in kubectl, the script uses it
# automatically. Otherwise it falls back to `default`.
NAMESPACE="${NAMESPACE:-$(current_namespace)}"
SLICE_COUNT="2"
UES_PER_SLICE="1"
GNB_COUNT="1"
EVENT_EXPOSURE="false"
UERANSIM_ENABLED="true"
SCENARIO_DIR=""

# These are the Helm release names the script creates.
TOOLBOX_RELEASE="xnet-toolbox"
CORE_RELEASE="xnet-open5gs"
RAN_RELEASE="xnet-ueransim"
SUBSCRIPTION_MANAGER_RELEASE="open5gs-subscriber-manager"

# These are the published chart locations used by default.
TOOLBOX_CHART="oci://ghcr.io/niloysh/charts/xnet-toolbox:0.1.0"
CORE_CHART="oci://ghcr.io/niloysh/charts/xnet-open5gs:0.1.0"
RAN_CHART="oci://ghcr.io/niloysh/charts/xnet-ueransim:0.1.0"
SUBSCRIPTION_MANAGER_CHART="oci://ghcr.io/niloysh/charts/open5gs-subscriber-manager:0.1.2"

# The toolbox pod writes the generated values files here before they are copied
# back to your local scenario bundle directory.
TOOLBOX_OUTPUT_DIR="/toolbox/out"

# --- Helpers ---
step()    { printf '\n:: %s\n' "$1"; }
success() { printf ':: %s\n' "$1"; }
info()    { echo "   $1"; }
warning() { printf 'warning: %s\n' "$1"; }
error()   { printf 'error: %s\n' "$1" >&2; }
is_true() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# Show the supported commands and options.
usage() {
  cat <<EOF
Usage: $(basename "$0") <action> [options]

Actions:
  up      Deploy the scenario environment
  down    Tear down the scenario environment

Options:
  --scenario-dir    Directory containing scenario values files
  --namespace       Kubernetes namespace       (default: ${NAMESPACE})
  --slice-count     Number of 5G slices         (default: 2)
  --ues-per-slice   Simulated UEs per slice     (default: 1)
  --gnb-count       Number of gNBs              (default: 1, max 20)
  --event-exposure  Enable event exposure       (default: false)
  --no-ueransim     Disable UERANSIM/RAN        (default: enabled)
  -h, --help        Show this help message

Examples:
  $(basename "$0") up
  $(basename "$0") up --scenario-dir demo/nwdaf
  $(basename "$0") up --slice-count 3 --ues-per-slice 2
  $(basename "$0") up --gnb-count 2 --ues-per-slice 2
  $(basename "$0") up --event-exposure
  $(basename "$0") down
EOF
}

# Make sure the required CLI tools are installed before doing any work.
require_prereqs() {
  for cmd in kubectl helm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      error "required command not found: $cmd"
      exit 1
    fi
  done
}

# Make sure kubectl can reach the cluster before starting the scenario steps.
require_cluster_access() {
  local output

  if output="$(kubectl cluster-info 2>&1)"; then
    return 0
  fi

  error "cannot reach the Kubernetes API"
  error "make sure kubectl works and your SSH tunnel to the Oceanus gateway is up"
  printf '%s\n' "${output}" >&2
  exit 1
}

# Look up the current toolbox pod so the generated files can be copied out.
toolbox_pod_name() {
  kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=xnet-toolbox \
    -o jsonpath='{.items[0].metadata.name}'
}

# Store the generated bundle in a stable local directory so you can inspect or
# reuse the rendered overlay values after a run. Set BUNDLE_DIR to override it.
bundle_dir() {
  echo "${BUNDLE_DIR:-${ROOT_DIR}/.scenario}"
}

# Use a provided scenario directory when one is supplied. Otherwise use the
# locally generated scenario files.
scenario_values_dir() {
  if [[ -n "${SCENARIO_DIR}" ]]; then
    echo "${SCENARIO_DIR}"
  else
    echo "$(bundle_dir)"
  fi
}

# Install or upgrade a Helm release. If Helm reports that a release exists but
# has no deployed revision, clean up the leftover Helm metadata and retry once.
helm_upgrade_install() {
  local release="$1"
  shift

  local output
  if output="$(helm upgrade --install "${release}" "$@" 2>&1)"; then
    printf '%s\n' "${output}"
    return 0
  fi

  if printf '%s' "${output}" | grep -q 'has no deployed releases'; then
    warning "Release ${release} is in a broken state. Removing it and retrying."
    purge_helm_release "${release}"

    if output="$(helm upgrade --install "${release}" "$@" 2>&1)"; then
      printf '%s\n' "${output}"
      return 0
    fi
  fi

  printf '%s\n' "${output}" >&2
  return 1
}

# Remove both the live release and any leftover Helm bookkeeping objects. This
# helps recover from interrupted or partially failed releases.
purge_helm_release() {
  local release="$1"

  helm uninstall "${release}" -n "${NAMESPACE}" --wait >/dev/null 2>&1 || true

  if kubectl get secret -n "${NAMESPACE}" -l "owner=helm,name=${release}" -o name 2>/dev/null | grep -q .; then
    warning "Deleting leftover Helm secrets for ${release}."
    kubectl delete secret -n "${NAMESPACE}" -l "owner=helm,name=${release}" >/dev/null 2>&1 || true
  fi

  if kubectl get configmap -n "${NAMESPACE}" -l "owner=helm,name=${release}" -o name 2>/dev/null | grep -q .; then
    warning "Deleting leftover Helm configmaps for ${release}."
    kubectl delete configmap -n "${NAMESPACE}" -l "owner=helm,name=${release}" >/dev/null 2>&1 || true
  fi
}

# Helm expects OCI charts in the form `oci://repo/chart --version x.y.z`, so
# split the inline chart reference into the format Helm wants.
helm_upgrade_install_chart() {
  local release="$1"
  local chart="$2"
  shift 2

  local chart_ref="${chart%:*}"
  local chart_version="${chart##*:}"

  helm_upgrade_install "${release}" "${chart_ref}" \
    --version "${chart_version}" \
    "$@"
}

# Remove old generated YAMLs so the local scenario bundle always reflects the
# latest run.
reset_local_bundle_dir() {
  mkdir -p "$(bundle_dir)"
  rm -f "$(bundle_dir)"/*.yaml
}

# Resolve and validate a user-provided scenario directory before deployment.
validate_scenario_dir() {
  local required_file

  [[ -n "${SCENARIO_DIR}" ]] || return 0

  if [[ ! -d "${SCENARIO_DIR}" ]]; then
    error "scenario directory not found: ${SCENARIO_DIR}"
    exit 1
  fi

  SCENARIO_DIR="$(cd "${SCENARIO_DIR}" && pwd)"

  for required_file in open5gs-values.yaml subscriber-values.yaml; do
    if [[ ! -f "${SCENARIO_DIR}/${required_file}" ]]; then
      error "scenario directory is missing ${required_file}: ${SCENARIO_DIR}"
      exit 1
    fi
  done
}

# Install the toolbox chart. After the scenario is up, you can also use the
# toolbox pod to run helper scripts such as `ue-ping-check.sh`.
# --- Steps ---
install_toolbox() {
  step "Installing toolbox"
  helm_upgrade_install_chart "${TOOLBOX_RELEASE}" "${TOOLBOX_CHART}" \
    -n "${NAMESPACE}" \
    --wait
  success "Toolbox ready."
}

generate_bundle() {
  step "Generating config bundle (slices=${SLICE_COUNT}, UEs/slice=${UES_PER_SLICE}, gNBs=${GNB_COUNT})"
  reset_local_bundle_dir

  # Clear any previous toolbox output so only files from this run are copied
  # back to the local scenario bundle directory.
  kubectl exec -n "${NAMESPACE}" deploy/xnet-toolbox -- bash -lc "rm -rf ${TOOLBOX_OUTPUT_DIR}/*"

  local build_cmd=(
    kubectl exec -n "${NAMESPACE}" deploy/xnet-toolbox --
    python3 /toolbox/build-scenario.py
    --slice-count "${SLICE_COUNT}"
    --ues-per-slice "${UES_PER_SLICE}"
    --gnb-count "${GNB_COUNT}"
    --out "${TOOLBOX_OUTPUT_DIR}"
  )

  # Translate the shell flags into the exact builder arguments.
  is_true "${EVENT_EXPOSURE}"   && build_cmd+=( --event-exposure )
  is_true "${UERANSIM_ENABLED}" && build_cmd+=( --ueransim ) || build_cmd+=( --no-ueransim )
  "${build_cmd[@]}"

  kubectl cp -n "${NAMESPACE}" "$(toolbox_pod_name):${TOOLBOX_OUTPUT_DIR}/." "$(bundle_dir)/"
  success "Bundle generated in $(bundle_dir)."
}

# Use the files from `--scenario-dir` when one is provided. Otherwise generate
# fresh scenario files through the toolbox pod.
prepare_scenario_values() {
  if [[ -n "${SCENARIO_DIR}" ]]; then
    step "Using scenario files from ${SCENARIO_DIR}"
    success "Scenario files ready."
    return 0
  fi

  generate_bundle
}

# Install the Open5GS core using the generated values.
install_core() {
  local values_dir
  values_dir="$(scenario_values_dir)"

  step "Installing 5G core (Open5GS)"
  helm_upgrade_install_chart "${CORE_RELEASE}" "${CORE_CHART}" \
    -n "${NAMESPACE}" \
    --wait \
    -f "${values_dir}/open5gs-values.yaml"
  success "Core ready."
}

# Install the subscriber manager, then wait for its seed job to finish so the
# generated UE identities are present in the database.
install_subscription_manager() {
  local values_dir
  values_dir="$(scenario_values_dir)"

  step "Installing subscription manager"
  helm_upgrade_install_chart "${SUBSCRIPTION_MANAGER_RELEASE}" "${SUBSCRIPTION_MANAGER_CHART}" \
    -n "${NAMESPACE}" \
    --wait --timeout 180s \
    -f "${values_dir}/subscriber-values.yaml"

  local seed_job
  seed_job="$(kubectl get jobs -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${SUBSCRIPTION_MANAGER_RELEASE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep seed | tail -n 1)"

  if [[ -z "${seed_job}" ]]; then
    error "Could not find seed job — subscribers may not be registered."
    return 1
  fi

  if ! kubectl wait -n "${NAMESPACE}" --for=condition=complete "job/${seed_job}" --timeout=240s; then
    error "Seed job did not complete. Logs:"
    kubectl logs -n "${NAMESPACE}" "job/${seed_job}" --tail=50 || true
    return 1
  fi

  success "Subscribers seeded."
}

# Install UERANSIM only when the generated bundle includes its values file.
install_ran() {
  local values_dir values
  values_dir="$(scenario_values_dir)"
  values="${values_dir}/ueransim-values.yaml"
  [[ -f "${values}" ]] || { info "No UERANSIM values found, skipping RAN."; return 0; }

  step "Installing RAN (UERANSIM)"
  helm_upgrade_install_chart "${RAN_RELEASE}" "${RAN_CHART}" \
    -n "${NAMESPACE}" \
    --wait \
    -f "${values}"
  success "RAN ready."
}

# --- Actions ---
deploy_scenario() {
  require_prereqs
  require_cluster_access
  validate_scenario_dir
  install_toolbox
  prepare_scenario_values
  install_core
  install_subscription_manager
  install_ran
  success "Scenario is up."
}

# Tear everything down in reverse dependency order.
teardown_scenario() {
  require_prereqs
  require_cluster_access
  for release in "${RAN_RELEASE}" "${SUBSCRIPTION_MANAGER_RELEASE}" "${CORE_RELEASE}" "${TOOLBOX_RELEASE}"; do
    step "Removing ${release}"
    purge_helm_release "${release}"
    success "Removed ${release}."
  done

  step "Cleaning bundle"
  if [[ -z "${SCENARIO_DIR}" ]]; then
    rm -rf "$(bundle_dir)"
    success "Done. Bundle removed."
  else
    success "Done."
  fi
}

# Parse the options that come after the action name.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --scenario-dir)   SCENARIO_DIR="$2";      shift 2 ;;
    --namespace)      NAMESPACE="$2";        shift 2 ;;
    --slice-count)     SLICE_COUNT="$2";      shift 2 ;;
    --ues-per-slice)   UES_PER_SLICE="$2";    shift 2 ;;
    --gnb-count)       GNB_COUNT="$2";        shift 2 ;;
    --event-exposure)  EVENT_EXPOSURE="true";  shift   ;;
    --no-ueransim)     UERANSIM_ENABLED="false"; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) error "unknown option: $1"; usage >&2; exit 1 ;;
    esac
  done
}

# Run the selected action.
run_action() {
  case "${ACTION}" in
    up)        deploy_scenario ;;
    down)      teardown_scenario ;;
    -h|--help) usage ;;
    *)
      error "unknown action: ${ACTION}"
      usage >&2
      exit 1
      ;;
  esac
}

# --- Entrypoint ---
ACTION="${1:-}"
if [[ -z "${ACTION}" ]]; then
  usage
  exit 1
fi
shift

parse_args "$@"
run_action
