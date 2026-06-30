#!/usr/bin/env bash
# =============================================================================
# kind-up.sh — spin up a local Kubernetes (kind) cluster and deploy the whole
# stack from infra/k8s, using locally built images (no registry needed).
#
#   ./scripts/kind-up.sh            # create cluster + build + deploy + test
#   ./scripts/kind-down.sh          # tear it down
#
# Requires: docker, kind, kubectl, kustomize, openssl.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

CLUSTER="${CLUSTER:-ticketing}"
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.34.0}"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

log "Creating kind cluster '${CLUSTER}' (etcd fsync disabled for disk safety)"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "cluster already exists — reusing"
else
  kind create cluster --name "${CLUSTER}" --image "${NODE_IMAGE}" \
    --config scripts/kind/kind-cluster.yaml --wait 120s
fi

log "Building runtime images"
docker build -q -f api/Containerfile      --target runtime -t ticketing-api:local      api
docker build -q -f frontend/Containerfile --target runtime -t ticketing-frontend:local frontend
docker build -q -f worker/Containerfile   --target runtime -t ticketing-worker:local   worker

log "Loading images into kind"
kind load docker-image ticketing-api:local ticketing-frontend:local ticketing-worker:local --name "${CLUSTER}"

log "Creating namespace + secret"
kubectl apply -f infra/k8s/00-namespace.yaml
kubectl -n ticketing create secret generic ticketing-secret \
  --from-literal=POSTGRES_PASSWORD="localdevpass123" \
  --from-literal=JWT_SECRET="$(openssl rand -hex 16)" \
  --from-literal=DATABASE_URL="postgresql://ticketing_user:localdevpass123@postgres:5432/ticketing" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Applying manifests (local image override)"
kustomize build infra/k8s \
  | sed -E \
      -e 's#ghcr.io/antonio-m3/secure-event-ticketing-platform-api:[^ ]+#ticketing-api:local#' \
      -e 's#ghcr.io/antonio-m3/secure-event-ticketing-platform-frontend:[^ ]+#ticketing-frontend:local#' \
      -e 's#ghcr.io/antonio-m3/secure-event-ticketing-platform-worker:[^ ]+#ticketing-worker:local#' \
  | kubectl apply -f -

log "Waiting for rollouts"
for d in postgres redis api worker frontend; do
  kubectl -n ticketing rollout status deployment/$d --timeout=180s
done

log "Cluster state"
kubectl -n ticketing get pods -o wide

log "Done. Test with:"
cat <<'EOF'
  kubectl -n ticketing port-forward svc/api 8080:8080
  curl http://localhost:8080/readyz
  curl http://localhost:8080/events
EOF
