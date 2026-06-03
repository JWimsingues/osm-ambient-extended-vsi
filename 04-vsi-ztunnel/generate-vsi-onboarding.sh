#!/usr/bin/env bash
# Generate VSI onboarding bundle and apply WorkloadEntry with parameterized IP.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

: "${VSI_PRIVATE_IP:?Set VSI_PRIVATE_IP to the VSI private IPv4}"
EW_GATEWAY_HOST="${EW_GATEWAY_HOST:-$(oc -n istio-system get svc istio-eastwestgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)}"
ISTIOD_GATEWAY_HOST="${ISTIOD_GATEWAY_HOST:-$(oc -n istio-system get svc istiod-xds-external -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)}"
if [[ -z "${ISTIOD_GATEWAY_HOST}" ]]; then
  ISTIOD_GATEWAY_HOST="${EW_GATEWAY_HOST}"
  echo "WARN: istiod-xds-external not found — using east-west gateway for xDS (may TLS-fail); apply 02-ambient-mesh/06-expose-istiod-lb.yaml" >&2
fi
: "${EW_GATEWAY_HOST:?Set EW_GATEWAY_HOST or deploy istio-eastwestgateway}"
: "${ISTIOD_GATEWAY_HOST:?Set ISTIOD_GATEWAY_HOST or apply 06-expose-istiod-lb.yaml}"

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

resolve_host_ip() {
  local host="$1"
  if [[ "${host}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${host}"
    return
  fi
  python3 -c "import socket; print(socket.gethostbyname('${host}'))" 2>/dev/null \
    || dig +short "${host}" A 2>/dev/null | awk 'NF {print; exit}' \
    || getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1; exit}'
}

ISTIOD_GATEWAY_IP="$(resolve_host_ip "${ISTIOD_GATEWAY_HOST}")"
INGRESS_IP_ARGS=()
if [[ -n "${ISTIOD_GATEWAY_IP}" ]]; then
  INGRESS_IP_ARGS=(--ingressIP "${ISTIOD_GATEWAY_IP}")
  echo "==> istiod xDS LB: ${ISTIOD_GATEWAY_HOST} -> ${ISTIOD_GATEWAY_IP}"
else
  echo "WARN: cannot resolve ${ISTIOD_GATEWAY_HOST} on this host — omitting --ingressIP (VSI install resolves at runtime)" >&2
  echo "==> istiod xDS LB hostname: ${ISTIOD_GATEWAY_HOST}"
fi
echo "==> east-west HBONE LB: ${EW_GATEWAY_HOST}"

if [[ ${#INGRESS_IP_ARGS[@]} -gt 0 ]]; then
  istioctl x workload entry configure \
    -f "${WORKLOAD_C_RENDERED}" \
    --clusterID "${CLUSTER_ID}" \
    "${INGRESS_IP_ARGS[@]}" \
    -o "${OUT_DIR}" \
    --tokenDuration="${TOKEN_DURATION}"
else
  istioctl x workload entry configure \
    -f "${WORKLOAD_C_RENDERED}" \
    --clusterID "${CLUSTER_ID}" \
    -o "${OUT_DIR}" \
    --tokenDuration="${TOKEN_DURATION}"
fi

# ztunnel xDS/CA requires audience istio-ca (not the default Kubernetes API audience).
oc -n osm-poc-demo create token ms-c --duration="${TOKEN_DURATION}s" --audience=istio-ca >"${OUT_DIR}/istio-token"
chmod 0644 "${OUT_DIR}/istio-token"
echo "==> Wrote istio-token for service account ms-c (audience=istio-ca, ${TOKEN_DURATION}s)"

SERVICE_CIDR="$(oc get network cluster -o jsonpath='{.status.serviceNetwork[0]}' 2>/dev/null || true)"
if [[ -z "${SERVICE_CIDR}" ]]; then
  SERVICE_CIDR="172.21.0.0/16"
  echo "WARN: could not read cluster serviceNetwork — defaulting to ${SERVICE_CIDR}" >&2
fi

cat >"${OUT_DIR}/service.env" <<EOF
# Cluster Service CIDR — used by setup-ztunnel-redirect.sh on the VSI.
SERVICE_CIDR=${SERVICE_CIDR}
EOF

# Resolve istiod LB IP from cluster DNS (workstation DNS may not see IBM LB yet).
ISTIOD_GATEWAY_IP="$(oc -n osm-poc-demo run istiod-dns --rm -i --restart=Never \
  --image=busybox:1.36 --command -- nslookup "${ISTIOD_GATEWAY_HOST}" 2>/dev/null \
  | awk '/^Address: / { print $2; exit }' || true)"
if [[ -z "${ISTIOD_GATEWAY_IP}" ]]; then
  ISTIOD_GATEWAY_IP="$(resolve_host_ip "${ISTIOD_GATEWAY_HOST}")"
fi
EW_GATEWAY_IP="$(oc -n osm-poc-demo run ew-dns --rm -i --restart=Never \
  --image=busybox:1.36 --command -- nslookup "${EW_GATEWAY_HOST}" 2>/dev/null \
  | awk '/^Address: / { print $2; exit }' || true)"
if [[ -z "${EW_GATEWAY_IP}" ]]; then
  EW_GATEWAY_IP="$(resolve_host_ip "${EW_GATEWAY_HOST}")"
fi

cat >"${OUT_DIR}/ew-gateway.env" <<EOF
EW_GATEWAY_HOST=${EW_GATEWAY_HOST}
EW_GATEWAY_IP=${EW_GATEWAY_IP:-}
ISTIOD_GATEWAY_HOST=${ISTIOD_GATEWAY_HOST}
ISTIOD_GATEWAY_IP=${ISTIOD_GATEWAY_IP:-}
EOF
echo "==> Done. Copy ${OUT_DIR}/ to the VSI and run install-ztunnel.sh"
