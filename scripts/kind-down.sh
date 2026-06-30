#!/usr/bin/env bash
# Tear down the local kind cluster created by kind-up.sh.
set -euo pipefail
CLUSTER="${CLUSTER:-ticketing}"
kind delete cluster --name "${CLUSTER}"
echo "kind cluster '${CLUSTER}' deleted."
