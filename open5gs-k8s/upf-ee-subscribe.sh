#!/usr/bin/env bash
set -euo pipefail

# Deploy a UPF Event Exposure subscriber pod that registers with the UPF EE
# API and streams usage notifications back via HTTP callback. The subscriber
# runs as a Deployment + Service in the target namespace.

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

# --- Defaults ---
NAMESPACE="$(current_namespace)"
NAME="xnet-upf-ee-subscriber"
IMAGE="ghcr.io/niloysh/xnet-upf-ee-subscriber:latest"
UPF_SERVICE="upf1-service"
UPF_EVENT_PORT="4355"
LISTEN_PORT="5000"
SUBSCRIPTION_PATH="/nupf-ee/v1/ee-subscriptions"
DNN=""
UE_IPV4=""
ANY_UE="true"
SST=""
SD=""
EVENT_TYPE="USER_DATA_USAGE_MEASURES"
REPORT_GRANULARITY="PER_FLOW"
REPORT_PERIOD="3"
SUBSCRIPTION_ID=""

# --- Helpers ---
step()    { printf '\n:: %s\n' "$1"; }
success() { printf ':: %s\n' "$1"; }
info()    { echo "   $1"; }
warning() { printf 'warning: %s\n' "$1"; }
error()   { printf 'error: %s\n' "$1" >&2; }

usage() {
  cat <<EOF
Usage: $(basename "$0") <action> [options]

Actions:
  up      Deploy the EE subscriber and stream notifications
  down    Delete the UPF subscription and remove the subscriber
  list    List all active subscriptions from the UPF EE API
  get     Get a specific subscription by ID
  delete  Delete a specific UPF EE subscription by ID
  logs    Stream logs from a running subscriber
  status  Show subscriber resources in the namespace

Options:
  --namespace           Kubernetes namespace              (default: ${NAMESPACE})
  --name                Name for the subscriber resources (default: ${NAME})
  --image               Subscriber container image        (default: ${IMAGE})
  --upf-service         UPF event exposure service name  (default: ${UPF_SERVICE})
  --upf-event-port      UPF event exposure port           (default: ${UPF_EVENT_PORT})
  --listen-port         Callback HTTP listen port         (default: ${LISTEN_PORT})
  --dnn                 DNN/APN filter (e.g. slice1)
  --ue-ipv4             UE IPv4 filter (e.g. 10.41.0.2)
  --any-ue              Subscribe for any UE              (default: ${ANY_UE})
  --sst                 S-NSSAI SST filter
  --sd                  S-NSSAI SD filter
  --event-type          Event type to subscribe to        (default: ${EVENT_TYPE})
  --report-granularity  Measurement granularity           (default: ${REPORT_GRANULARITY})
  --report-period       Reporting period in seconds       (default: ${REPORT_PERIOD})
  --id                  Subscription ID for the delete action
  -h, --help            Show this help message

Examples:
  $(basename "$0") up
  $(basename "$0") up --namespace demo --dnn slice1
  $(basename "$0") up --namespace demo --ue-ipv4 10.41.0.2 --any-ue false
  $(basename "$0") up --event-type USER_DATA_USAGE_TRENDS --report-period 5
  $(basename "$0") list --namespace demo
  $(basename "$0") get --namespace demo --id <subscription-id>
  $(basename "$0") delete --namespace demo --id <subscription-id>
  $(basename "$0") logs --namespace demo
  $(basename "$0") down --namespace demo
EOF
}

require_prereqs() {
  for cmd in kubectl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      error "required command not found: $cmd"
      exit 1
    fi
  done
}

require_cluster_access() {
  local output
  if output="$(kubectl cluster-info 2>&1)"; then
    return 0
  fi
  error "cannot reach the Kubernetes API"
  printf '%s\n' "${output}" >&2
  exit 1
}

subscription_url() {
  echo "http://${UPF_SERVICE}.${NAMESPACE}.svc.cluster.local:${UPF_EVENT_PORT}${SUBSCRIPTION_PATH}"
}

callback_url() {
  echo "http://${NAME}.${NAMESPACE}.svc.cluster.local:${LISTEN_PORT}/"
}

apply_resources() {
  kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${NAME}
  labels:
    app: ${NAME}
spec:
  selector:
    app: ${NAME}
  ports:
    - name: http
      port: ${LISTEN_PORT}
      targetPort: ${LISTEN_PORT}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${NAME}
  labels:
    app: ${NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${NAME}
  template:
    metadata:
      labels:
        app: ${NAME}
    spec:
      containers:
        - name: subscriber
          image: ${IMAGE}
          imagePullPolicy: Always
          env:
            - name: SUBSCRIPTION_URL
              value: $(subscription_url)
            - name: CALLBACK_URL
              value: $(callback_url)
            - name: LISTEN_PORT
              value: "${LISTEN_PORT}"
            - name: DNN
              value: "${DNN}"
            - name: UE_IPV4
              value: "${UE_IPV4}"
            - name: ANY_UE
              value: "${ANY_UE}"
            - name: SST
              value: "${SST}"
            - name: SD
              value: "${SD}"
            - name: EVENT_TYPE
              value: "${EVENT_TYPE}"
            - name: REPORT_GRANULARITY
              value: "${REPORT_GRANULARITY}"
            - name: REPORT_PERIOD
              value: "${REPORT_PERIOD}"
          ports:
            - containerPort: ${LISTEN_PORT}
              name: http
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 10
            periodSeconds: 20
EOF
}

list_subscription_ids() {
  cluster_python - "$(subscription_url)" <<'PY'
import sys
import json
import urllib.error
import urllib.request

url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=10) as response:
        data = json.loads(response.read().decode("utf-8", errors="replace"))
        for entry in data:
            print(entry["subscriptionId"])
except Exception as exc:
    print(f"error: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

cluster_python() {
  local ready
  ready="$(kubectl get deployment/"${NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"

  if [[ ! "${ready}" =~ ^[1-9] ]]; then
    error "Subscriber is not running. Run '$(basename "$0") up' first."
    exit 1
  fi

  kubectl exec -i -n "${NAMESPACE}" deployment/"${NAME}" -- python "$@"
}

delete_subscription() {
  local subscription_id="$1"
  cluster_python - "$(subscription_url)/${subscription_id}" <<'PY'
import sys
import urllib.error
import urllib.request

delete_url = sys.argv[1]
request = urllib.request.Request(delete_url, method="DELETE")

try:
    with urllib.request.urlopen(request, timeout=10) as response:
        body = response.read().decode("utf-8", errors="replace")
        print(f"delete-response: {response.status} {body}")
except urllib.error.HTTPError as exc:
    body = exc.read().decode("utf-8", errors="replace")
    print(f"delete-http-error: {exc.code} {body}", file=sys.stderr)
    sys.exit(1)
except Exception as exc:
    print(f"delete-error: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

list_subscriptions() {
  cluster_python - "$(subscription_url)" <<'PY'
import sys
import json
import urllib.error
import urllib.request

url = sys.argv[1]
request = urllib.request.Request(url, method="GET")

try:
    with urllib.request.urlopen(request, timeout=10) as response:
        body = response.read().decode("utf-8", errors="replace")
        try:
            data = json.loads(body)
            print(json.dumps(data))
        except json.JSONDecodeError:
            print(body)
except urllib.error.HTTPError as exc:
    body = exc.read().decode("utf-8", errors="replace")
    print(f"http-error: {exc.code} {body}", file=sys.stderr)
    sys.exit(1)
except Exception as exc:
    print(f"error: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

list() {
  require_prereqs
  require_cluster_access

  step "Listing UPF EE subscriptions"
  info "Endpoint: $(subscription_url)"
  list_subscriptions
}

get_subscription() {
  local subscription_id="$1"
  cluster_python - "$(subscription_url)/${subscription_id}" <<'PY'
import sys
import json
import urllib.error
import urllib.request

url = sys.argv[1]
request = urllib.request.Request(url, method="GET")

try:
    with urllib.request.urlopen(request, timeout=10) as response:
        body = response.read().decode("utf-8", errors="replace")
        try:
            data = json.loads(body)
            print(json.dumps(data))
        except json.JSONDecodeError:
            print(body)
except urllib.error.HTTPError as exc:
    body = exc.read().decode("utf-8", errors="replace")
    print(f"http-error: {exc.code} {body}", file=sys.stderr)
    sys.exit(1)
except Exception as exc:
    print(f"error: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

get() {
  require_prereqs
  require_cluster_access

  if [[ -z "${SUBSCRIPTION_ID}" ]]; then
    error "Subscription ID required. Use --id <id>."
    exit 1
  fi

  step "Getting UPF EE subscription"
  info "ID: ${SUBSCRIPTION_ID}"
  get_subscription "${SUBSCRIPTION_ID}"
}

delete() {
  require_prereqs
  require_cluster_access

  step "Deleting UPF EE subscription"
  local subscription_id="${SUBSCRIPTION_ID}"

  if [[ -z "${subscription_id}" ]]; then
    error "Subscription ID required. Use --id <id>."
    exit 1
  fi

  info "Deleting subscription ${subscription_id}..."
  delete_subscription "${subscription_id}"
  success "Subscription ${subscription_id} deleted."
}

up() {
  require_prereqs
  require_cluster_access

  step "Deploying UPF EE subscriber"
  info "Namespace:    ${NAMESPACE}"
  info "Image:        ${IMAGE}"
  info "Subscription: $(subscription_url)"
  info "Callback:     $(callback_url)"
  info "Event type:   ${EVENT_TYPE} (granularity=${REPORT_GRANULARITY}, period=${REPORT_PERIOD}s)"
  [[ -n "${DNN}" ]]    && info "DNN:          ${DNN}"
  [[ -n "${UE_IPV4}" ]] && info "UE IPv4:      ${UE_IPV4}"
  [[ -n "${SST}" ]]    && info "S-NSSAI:      sst=${SST} sd=${SD}"

  apply_resources
  kubectl rollout status deployment/"${NAME}" -n "${NAMESPACE}" --timeout=120s
  success "Subscriber deployed. Streaming notifications (Ctrl-C to stop)..."
  kubectl logs -n "${NAMESPACE}" deployment/"${NAME}" -f
}

down() {
  require_prereqs
  require_cluster_access

  step "Removing UPF EE subscriber"
  local ids
  ids="$(list_subscription_ids 2>/dev/null || true)"
  if [[ -n "${ids}" ]]; then
    while IFS= read -r id; do
      info "Deleting UPF subscription ${id}..."
      delete_subscription "${id}" || true
    done <<< "${ids}"
  else
    warning "No active subscriptions found — skipping UPF DELETE."
  fi

  kubectl delete deployment,service -n "${NAMESPACE}" "${NAME}" --ignore-not-found
  success "Subscriber removed."
}

logs() {
  require_prereqs
  kubectl logs -n "${NAMESPACE}" deployment/"${NAME}" --tail="${TAIL_LINES:-200}" -f
}

status() {
  require_prereqs
  kubectl get service,deployment,pod -n "${NAMESPACE}" -l app="${NAME}" || true
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace)          NAMESPACE="$2";          shift 2 ;;
      --name)               NAME="$2";               shift 2 ;;
      --image)              IMAGE="$2";              shift 2 ;;
      --upf-service)        UPF_SERVICE="$2";        shift 2 ;;
      --upf-event-port)     UPF_EVENT_PORT="$2";     shift 2 ;;
      --listen-port)        LISTEN_PORT="$2";        shift 2 ;;
      --dnn)                DNN="$2";                shift 2 ;;
      --ue-ipv4)            UE_IPV4="$2";            shift 2 ;;
      --any-ue)             ANY_UE="$2";             shift 2 ;;
      --sst)                SST="$2";                shift 2 ;;
      --sd)                 SD="$2";                 shift 2 ;;
      --event-type)         EVENT_TYPE="$2";         shift 2 ;;
      --report-granularity) REPORT_GRANULARITY="$2"; shift 2 ;;
      --report-period)      REPORT_PERIOD="$2";      shift 2 ;;
      --id)                 SUBSCRIPTION_ID="$2";    shift 2 ;;
      -h|--help)            usage; exit 0 ;;
      *) error "unknown option: $1"; usage >&2; exit 1 ;;
    esac
  done
}

run_action() {
  case "${ACTION}" in
    up)           up ;;
    down)         down ;;
    list)         list ;;
    get)          get ;;
    delete)       delete ;;
    logs)         logs ;;
    status)       status ;;
    -h|--help)    usage ;;
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
