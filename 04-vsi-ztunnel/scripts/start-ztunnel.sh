#!/usr/bin/env bash
# Resolve east-west gateway IP at runtime and start ztunnel (LB IPs can change).
set -euo pipefail

EW_GATEWAY_CONFIG=/etc/istio/ew-gateway.env
# shellcheck source=/dev/null
[[ -f "${EW_GATEWAY_CONFIG}" ]] && source "${EW_GATEWAY_CONFIG}"
: "${EW_GATEWAY_HOST:?EW_GATEWAY_HOST not set in ${EW_GATEWAY_CONFIG}}"

: "${ZTUNNEL_IMAGE:=docker.io/istio/ztunnel:1.28.6}"
: "${PROXY_WORKLOAD_INFO:=osm-poc-demo/ms-c-vsi/ms-c}"

if [[ "${EW_GATEWAY_HOST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  EW_GATEWAY_IP="${EW_GATEWAY_HOST}"
else
  EW_GATEWAY_IP="$(getent ahostsv4 "${EW_GATEWAY_HOST}" | awk '{print $1; exit}')"
fi
if [[ -z "${EW_GATEWAY_IP}" ]]; then
  echo "ERROR: cannot resolve EW_GATEWAY_HOST=${EW_GATEWAY_HOST}" >&2
  exit 1
fi

grep -v 'istiod\.istio-system\.svc' /etc/hosts > /etc/hosts.tmp || true
mv /etc/hosts.tmp /etc/hosts
cat >>/etc/hosts <<HOSTS
${EW_GATEWAY_IP} istiod.istio-system.svc istiod.istio-system.svc.cluster.local
HOSTS

exec /usr/bin/podman run --rm --name ztunnel \
  --network host \
  --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_ADMIN \
  -v /var/lib/istio:/var/lib/istio \
  -v /var/run/secrets/tokens:/var/run/secrets/tokens \
  -v /var/run/secrets/istio:/var/run/secrets/istio \
  -v /etc/certs:/etc/certs \
  -v /etc/istio/config:/etc/istio/config \
  -v /etc/istio/proxy:/etc/istio/proxy \
  -v /etc/hosts:/etc/hosts:ro \
  --add-host "istiod.istio-system.svc:${EW_GATEWAY_IP}" \
  --add-host "istiod.istio-system.svc.cluster.local:${EW_GATEWAY_IP}" \
  -e PROXY_MODE=dedicated \
  -e PROXY_WORKLOAD_INFO="${PROXY_WORKLOAD_INFO}" \
  -e NETWORK=vsi-network \
  -e SERVICE_ACCOUNT=ms-c \
  -e ISTIO_META_SERVICE_ACCOUNT=ms-c \
  -e ISTIO_META_NETWORK=vsi-network \
  -e CA_ADDRESS=istiod.istio-system.svc:15012 \
  -e XDS_ADDRESS=istiod.istio-system.svc:15012 \
  -e XDS_ROOT_CA=/var/run/secrets/istio/root-cert.pem \
  -e CA_ROOT_CA=/var/run/secrets/istio/root-cert.pem \
  -e ISTIO_META_CLUSTER_ID=rocks-cluster \
  -e CLUSTER_ID=rocks-cluster \
  -e ISTIO_META_ENABLE_HBONE=true \
  -e ISTIO_META_DNS_CAPTURE=true \
  -e ISTIO_META_DNS_AUTO_ALLOCATE=true \
  -e ISTIO_META_DNS_PROXY_ADDR=127.0.0.1:15053 \
  -e RUST_LOG=info \
  "${ZTUNNEL_IMAGE}"
