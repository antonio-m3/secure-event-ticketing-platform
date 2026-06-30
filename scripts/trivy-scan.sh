#!/usr/bin/env bash
# =============================================================================
# trivy-scan.sh — local security scanning helper for the ticketing platform.
#
# Runs three kinds of Trivy scans and stores results under
# docs/security/scans/:
#   1. image  scan of the locally built service images (if they exist)
#   2. fs     scan of each service directory (dependencies / source)
#   3. config scan of Containerfiles + Kubernetes manifests (IaC)
#
# Usage:
#   ./scripts/trivy-scan.sh                # scan everything it can find
#   ./scripts/trivy-scan.sh --build        # build images first, then scan
#   SEVERITY=CRITICAL ./scripts/trivy-scan.sh
#
# Quality gate: fixable HIGH/CRITICAL findings cause a non-zero exit so the
# script can be wired into a pre-commit hook or CI step.
#
# If Trivy is not installed the script prints install instructions and exits 0
# (so it never blocks a machine that simply has not set it up yet).
# =============================================================================
set -euo pipefail

# --- Resolve repo root regardless of where the script is called from ---------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

OUT_DIR="docs/security/scans"
mkdir -p "${OUT_DIR}"

SEVERITY="${SEVERITY:-HIGH,CRITICAL}"
SERVICES=(api frontend worker)
# Match the image names produced by compose (service:dev) — adjust if needed.
declare -A IMAGES=(
  [api]="ticketing-api:dev"
  [frontend]="ticketing-frontend:dev"
  [worker]="ticketing-worker:dev"
)

GATE_FAILED=0

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

# --- Preconditions -----------------------------------------------------------
if ! command -v trivy >/dev/null 2>&1; then
  warn "Trivy is not installed — nothing was scanned."
  cat <<'EOF'

Install Trivy, then re-run this script:
  # macOS
  brew install trivy
  # Debian/Ubuntu
  sudo apt-get install -y wget gnupg
  wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo apt-key add -
  echo "deb https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | \
    sudo tee /etc/apt/sources.list.d/trivy.list
  sudo apt-get update && sudo apt-get install -y trivy
  # Or run via container:
  #   docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  #     -v "$PWD:/work" aquasec/trivy:latest fs /work
EOF
  exit 0
fi

CONTAINER_CLI=""
if command -v docker >/dev/null 2>&1; then CONTAINER_CLI=docker
elif command -v podman >/dev/null 2>&1; then CONTAINER_CLI=podman
fi

# --- Optional: build images first -------------------------------------------
if [[ "${1:-}" == "--build" && -n "${CONTAINER_CLI}" ]]; then
  for svc in "${SERVICES[@]}"; do
    log "Building ${IMAGES[$svc]}"
    "${CONTAINER_CLI}" build -f "${svc}/Containerfile" --target runtime \
      -t "${IMAGES[$svc]}" "${svc}"
  done
fi

# --- 1. Image scans ----------------------------------------------------------
for svc in "${SERVICES[@]}"; do
  img="${IMAGES[$svc]}"
  if [[ -n "${CONTAINER_CLI}" ]] && "${CONTAINER_CLI}" image inspect "${img}" >/dev/null 2>&1; then
    log "Image scan: ${img}"
    trivy image --severity "${SEVERITY}" --ignore-unfixed \
      --format table --output "${OUT_DIR}/image-${svc}.txt" "${img}" || true
    # Gate copy: exit-code 1 on fixable HIGH/CRITICAL.
    if ! trivy image --severity "${SEVERITY}" --ignore-unfixed \
        --exit-code 1 --quiet "${img}" >/dev/null 2>&1; then
      warn "Quality gate: fixable ${SEVERITY} vulnerabilities in ${img}"
      GATE_FAILED=1
    fi
  else
    warn "Image ${img} not found locally — skipping (use --build or 'docker compose build')."
  fi
done

# --- 2. Filesystem scans (dependencies / source) ----------------------------
for svc in "${SERVICES[@]}"; do
  log "Filesystem scan: ${svc}/"
  trivy fs --severity "${SEVERITY}" --ignore-unfixed \
    --format table --output "${OUT_DIR}/fs-${svc}.txt" "${svc}" || true
done

# --- 3. Config / IaC scan (Containerfiles + k8s manifests) ------------------
log "Config (IaC) scan: Containerfiles + infra/k8s"
trivy config --severity "${SEVERITY}" \
  --format table --output "${OUT_DIR}/config-iac.txt" . || true
if ! trivy config --severity "${SEVERITY}" --exit-code 1 --quiet . >/dev/null 2>&1; then
  warn "Quality gate: ${SEVERITY} misconfigurations detected in IaC."
  GATE_FAILED=1
fi

log "Scan artifacts written to ${OUT_DIR}/"
ls -1 "${OUT_DIR}" || true

cat <<EOF

Next step: summarise these results in docs/security/image-scan-report.md
(scanned images, severity counts, quality-gate decision, remediation).
EOF

if [[ "${GATE_FAILED}" -ne 0 ]]; then
  warn "QUALITY GATE FAILED — fixable HIGH/CRITICAL issues present."
  exit 1
fi

log "Quality gate passed (no fixable ${SEVERITY} issues found)."
