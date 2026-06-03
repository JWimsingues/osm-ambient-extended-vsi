#!/usr/bin/env bash
# Apply ms-c WorkloadEntry + EndpointSlice with the VSI private IP (no hardcoded IP in git).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [[ -z "${VSI_PRIVATE_IP:-}" ]]; then
  cat >&2 <<'EOF'
ERROR: VSI_PRIVATE_IP is not set.

Example:
  export VSI_PRIVATE_IP=10.243.64.9
  ./apply-workload-c.sh
EOF
  exit 1
fi

export VSI_PRIVATE_IP
envsubst '${VSI_PRIVATE_IP}' < 05-workload-c.yaml | oc apply -f -
echo "Applied 05-workload-c.yaml with VSI_PRIVATE_IP=${VSI_PRIVATE_IP}"
