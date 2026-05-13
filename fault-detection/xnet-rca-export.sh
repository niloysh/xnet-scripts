#!/usr/bin/env bash
# Submit an in-cluster xnet-rca-export run and copy the dataset to the laptop.
#
# Usage:
#   bin/xnet-rca-export.sh -n <namespace> -w <window> -o <output-dir> [-- <extra-export-flags>...]
#
# Examples:
#   bin/xnet-rca-export.sh -n n6saha -w 1h -o ./out
#   bin/xnet-rca-export.sh -n n6saha -w 6h -o ./paper_dataset -- --fault-types cpu_stress
#   bin/xnet-rca-export.sh -n n6saha -o ./logs_too -- --start 2026-05-13T05:50:00Z --end 2026-05-13T06:30:00Z --include-logs
#
# Requirements (on the laptop):
#   - kubectl with credentials for the target cluster
#   - The xnet-rca Helm release installed in <namespace> (provides the SA + RBAC)
#
# How it works:
#   1. Create a one-shot Pod that runs xnet-rca-export against in-cluster VM/VL
#      (no port-forward needed because the Pod talks directly to the services).
#   2. The container exports, drops a .done sentinel, then sleeps so kubectl
#      exec can stream the artifacts out.
#   3. Stream /out as a tarball via `kubectl exec ... tar` into the laptop's
#      output dir. Single round-trip, no PVC, no kubectl cp directory weirdness.
#   4. Delete the Pod.

set -euo pipefail

usage() {
    grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' >&2
    exit "${1:-1}"
}

NAMESPACE=""
WINDOW=""
OUTPUT_DIR=""
IMAGE_TAG="${IMAGE_TAG:-v0.1.9}"
IMAGE="${IMAGE:-ghcr.io/niloysh/xnet-rca-export:${IMAGE_TAG}}"
MONITORING_NS="${MONITORING_NS:-monitoring}"
SA_NAME="${SA_NAME:-xnet-rca}"
TIMEOUT_S="${TIMEOUT_S:-600}"

EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)  NAMESPACE="$2"; shift 2 ;;
        -w|--window)     WINDOW="$2"; shift 2 ;;
        -o|--output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)       usage 0 ;;
        --)              shift; if [[ $# -gt 0 ]]; then EXTRA_ARGS=("$@"); fi; break ;;
        *)               echo "unknown arg: $1" >&2; usage 1 ;;
    esac
done

if [[ -z "$NAMESPACE" || -z "$OUTPUT_DIR" ]]; then
    echo "ERROR: -n <namespace> and -o <output-dir> are required" >&2
    usage 1
fi
if [[ -z "$WINDOW" && ${#EXTRA_ARGS[@]:-0} -eq 0 ]]; then
    echo "ERROR: must pass either -w <window> or '-- --start ... --end ...'" >&2
    usage 1
fi

mkdir -p "$OUTPUT_DIR"

POD_NAME="xnet-rca-export-$(date +%s)"

# Build the export command args. If --window is given, append it; everything
# after `--` on the wrapper gets appended too. The SA in-cluster already has
# the RBAC, and the direct service URLs skip the port-forward dance.
EXPORT_ARGS=(
    --target-namespace "$NAMESPACE"
    --output-dir /out
    --monitoring-namespace "$MONITORING_NS"
    --vm-url "http://vmsingle-xnet.${MONITORING_NS}:8429"
    --vl-url "http://vlsingle-xnet.${MONITORING_NS}:9428"
)
if [[ -n "$WINDOW" ]]; then
    EXPORT_ARGS+=(--window "$WINDOW")
fi
if [[ ${#EXTRA_ARGS[@]:-0} -gt 0 ]]; then
    EXPORT_ARGS+=("${EXTRA_ARGS[@]}")
fi

echo ">>> creating Pod $POD_NAME in $NAMESPACE"
echo "    image: $IMAGE"
echo "    args:  ${EXPORT_ARGS[*]}"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: xnet-rca-export-job
spec:
  serviceAccountName: ${SA_NAME}
  restartPolicy: Never
  containers:
    - name: export
      image: ${IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c"]
      args:
        - |
          set -e
          python -m scenarios.sweep.export $(printf '%q ' "${EXPORT_ARGS[@]}")
          touch /out/.done
          # Hold the volume alive so the laptop can stream it out.
          sleep ${TIMEOUT_S}
      volumeMounts:
        - name: out
          mountPath: /out
  volumes:
    - name: out
      emptyDir: {}
EOF

cleanup() {
    echo ">>> deleting Pod $POD_NAME"
    kubectl -n "$NAMESPACE" delete pod "$POD_NAME" --wait=false --ignore-not-found >/dev/null
}
trap cleanup EXIT

echo ">>> waiting for Pod to start"
kubectl -n "$NAMESPACE" wait "pod/${POD_NAME}" --for=condition=Ready --timeout="${TIMEOUT_S}s"

echo ">>> waiting for export to finish (looking for /out/.done sentinel)"
deadline=$(( $(date +%s) + TIMEOUT_S ))
until kubectl -n "$NAMESPACE" exec "$POD_NAME" -- test -f /out/.done 2>/dev/null; do
    if [[ $(date +%s) -gt $deadline ]]; then
        echo "ERROR: export did not finish within ${TIMEOUT_S}s" >&2
        kubectl -n "$NAMESPACE" logs "$POD_NAME" >&2 || true
        exit 2
    fi
    sleep 3
done

echo ">>> streaming /out → $OUTPUT_DIR"
kubectl -n "$NAMESPACE" exec "$POD_NAME" -- tar cf - -C /out --exclude=.done . \
    | tar xf - -C "$OUTPUT_DIR"

echo ">>> done. Artifacts under: $OUTPUT_DIR"
ls -1 "$OUTPUT_DIR"
