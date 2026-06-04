#!/usr/bin/env bash
# Apply ms-c mesh resources (ServiceAccount, WorkloadGroup, Service, ServiceEntry).
# The VM's IP is auto-registered by istiod when the VM sidecar connects in step 4.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

oc apply -f 05-workload-c.yaml
echo "Applied 05-workload-c.yaml"
echo "WorkloadEntry will appear automatically once the VM sidecar connects (step 4)."
