#!/usr/bin/env bash
# Generate VSI onboarding bundle and apply WorkloadEntry with parameterized IP.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

: "${VSI_PRIVATE_IP:?Set VSI_PRIVATE_IP to the VSI private IPv4}"
: "${EW_GATEWAY_HOST:?Set EW_GATEWAY_HOST from: oc -n istio-system get svc istio-eastwestgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'}"

export VSI_PRIVATE_IP
CLUSTER_ID="${CLUSTER_ID:-rocks-cluster}"
TOKEN_DURATION="${TOKEN_DURATION:-86400}"
OUT_DIR="${OUT_DIR:-${ROOT}/vsi-onboarding}"

echo "==> Applying WorkloadEntry / EndpointSlice with VSI_PRIVATE_IP=${VSI_PRIVATE_IP}"
"${ROOT}/../03-deploy-microservices/apply-workload-c.sh"

echo "==> Generating onboarding files in ${OUT_DIR}"
mkdir -p "${OUT_DIR}"
WORKLOAD_C_RENDERED="$(mktemp)"
trap 'rm -f "${WORKLOAD_C_RENDERED}"' EXIT
envsubst '${VSI_PRIVATE_IP}' <"${ROOT}/../03-deploy-microservices/05-workload-c.yaml" >"${WORKLOAD_C_RENDERED}"

if [[ "${EW_GATEWAY_HOST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  EW_GATEWAY_IP="${EW_GATEWAY_HOST}"
else
  EW_GATEWAY_IP="$(dig +short "${EW_GATEWAY_HOST}" A 2>/dev/null | awk 'NF {print; exit}')"
  if [[ -z "${EW_GATEWAY_IP}" ]]; then
    EW_GATEWAY_IP="$(getent ahostsv4 "${EW_GATEWAY_HOST}" 2>/dev/null | awk '{print $1; exit}')"
  fi
fi
if [[ -z "${EW_GATEWAY_IP}" ]]; then
  echo "ERROR: cannot resolve EW_GATEWAY_HOST=${EW_GATEWAY_HOST}" >&2
  exit 1
fi
echo "==> East-west gateway IP for istiod: ${EW_GATEWAY_IP}"

istioctl x workload entry configure \
  -f "${WORKLOAD_C_RENDERED}" \
  --clusterID "${CLUSTER_ID}" \
  --ingressIP "${EW_GATEWAY_IP}" \
  -o "${OUT_DIR}" \
  --tokenDuration="${TOKEN_DURATION}"

# istioctl may issue a token for SA "default"; ambient identity for ms-c must use SA ms-c.
oc -n osm-poc-demo create token ms-c --duration="${TOKEN_DURATION}s" >"${OUT_DIR}/istio-token"
chmod 0644 "${OUT_DIR}/istio-token"
echo "==> Wrote istio-token for service account ms-c (${TOKEN_DURATION}s)"

SERVICE_CIDR="$(oc get network cluster -o jsonpath='{.status.serviceNetwork[0]}' 2>/dev/null || true)"
if [[ -z "${SERVICE_CIDR}" ]]; then
  SERVICE_CIDR="172.21.0.0/16"
  echo "WARN: could not read cluster serviceNetwork — defaulting to ${SERVICE_CIDR}" >&2
fi

cat >"${OUT_DIR}/service.env" <<EOF
# Cluster Service CIDR — used by setup-ztunnel-redirect.sh on the VSI.
SERVICE_CIDR=${SERVICE_CIDR}
EOF

printf 'EW_GATEWAY_HOST=%q\n' "${EW_GATEWAY_HOST}" >"${OUT_DIR}/ew-gateway.env"
echo "==> Done. Copy ${OUT_DIR}/ to the VSI and run install-ztunnel.sh"
