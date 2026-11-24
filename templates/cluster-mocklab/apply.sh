#!/usr/bin/env bash
# Deploys / refreshes a MockLab inside a domain's namespace, so tasks that call http://mocklab:5000 work there.
# Run from the workspace root with an `oc` session on the target cluster:
#   NS={{namespace}} templates/cluster-mocklab/apply.sh          (copied into the workspace as deploy/mocklab/)
# Seed changes: re-run — it rebuilds the ConfigMap and restarts the pod (emptyDir DB → clean re-import).
set -euo pipefail
NS="${NS:-{{namespace}}}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${ROOT:-$(cd "$HERE/../.." && pwd)}"
SEED_DIR="${SEED_DIR:-$ROOT/etc/docker/config/seed}"
echo "server: $(oc whoami --show-server)  namespace: $NS  seed: $SEED_DIR"
oc -n "$NS" create configmap mocklab-seed --from-file="$SEED_DIR/" --dry-run=client -o yaml \
  | oc -n "$NS" label --local -f - app.kubernetes.io/part-of=vnext-{{domain}}-mocks -o yaml \
  | oc -n "$NS" apply -f -
oc -n "$NS" apply -f "$HERE/deployment.yaml" -f "$HERE/service.yaml"
oc -n "$NS" rollout restart deployment/mocklab
oc -n "$NS" rollout status deployment/mocklab --timeout=180s
