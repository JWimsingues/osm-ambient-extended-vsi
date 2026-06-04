#!/usr/bin/env bash
# Start native ztunnel (host network, no containers).
set -euo pipefail

EW_GATEWAY_CONFIG=/etc/istio/ew-gateway.env
# shellcheck source=/dev/null
[[ -f "${EW_GATEWAY_CONFIG}" ]] && source "${EW_GATEWAY_CONFIG}"
: "${ISTIOD_GATEWAY_HOST:=${EW_GATEWAY_HOST:-}}"
: "${ISTIOD_GATEWAY_HOST:?ISTIOD_GATEWAY_HOST or EW_GATEWAY_HOST must be set in ${EW_GATEWAY_CONFIG}}"

: "${ZTUNNEL_BIN:=/usr/local/bin/ztunnel}"
: "${ZTUNNEL_LIBS_ROOT:=/opt/istio/ztunnel-libs}"
: "${ZTUNNEL_LIB_DIR:=${ZTUNNEL_LIBS_ROOT}/usr/lib/x86_64-linux-gnu}"
: "${ZTUNNEL_LD:=${ZTUNNEL_LIBS_ROOT}/usr/lib64/ld-linux-x86-64.so.2}"
: "${PROXY_WORKLOAD_INFO:=osm-poc-demo/ms-c-vsi/ms-c}"

ztunnel_exec() {
  if [[ -f "${ZTUNNEL_LD}" && -f "${ZTUNNEL_LIB_DIR}/libc.so.6" ]]; then
    exec "${ZTUNNEL_LD}" --library-path "${ZTUNNEL_LIB_DIR}" "${ZTUNNEL_BIN}" "$@"
  fi
  exec "${ZTUNNEL_BIN}" "$@"
}

if [[ ! -x "${ZTUNNEL_BIN}" ]]; then
  echo "ERROR: ${ZTUNNEL_BIN} missing — re-run install-ztunnel.sh after copying vsi-onboarding/ztunnel" >&2
  exit 1
fi

if [[ -n "${ISTIOD_GATEWAY_IP:-}" ]]; then
  ISTIOD_IP="${ISTIOD_GATEWAY_IP}"
elif [[ "${ISTIOD_GATEWAY_HOST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  ISTIOD_IP="${ISTIOD_GATEWAY_HOST}"
else
  ISTIOD_IP="$(getent ahostsv4 "${ISTIOD_GATEWAY_HOST}" 2>/dev/null | awk '{print $1; exit}' || true)"
fi
if [[ -z "${ISTIOD_IP}" ]]; then
  echo "ERROR: cannot resolve ISTIOD_GATEWAY_HOST=${ISTIOD_GATEWAY_HOST}" >&2
  exit 1
fi

if [[ -n "${EW_GATEWAY_IP:-}" ]]; then
  EW_IP="${EW_GATEWAY_IP}"
elif [[ -n "${EW_GATEWAY_HOST:-}" ]]; then
  if [[ "${EW_GATEWAY_HOST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    EW_IP="${EW_GATEWAY_HOST}"
  else
    EW_IP="$(getent ahostsv4 "${EW_GATEWAY_HOST}" 2>/dev/null | awk '{print $1; exit}' || true)"
  fi
fi

# /etc/hosts is updated by install-ztunnel.sh (istio-proxy cannot write it at runtime).

export PROXY_MODE=dedicated
export PROXY_WORKLOAD_INFO="${PROXY_WORKLOAD_INFO}"
export NETWORK=vsi-network
export SERVICE_ACCOUNT=ms-c
export ISTIO_META_SERVICE_ACCOUNT=ms-c
export ISTIO_META_NETWORK=vsi-network
export CA_ADDRESS="${ISTIOD_IP}:15012"
export XDS_ADDRESS="${ISTIOD_IP}:15012"
export ALT_XDS_HOSTNAME=istiod.istio-system.svc
export ALT_CA_HOSTNAME=istiod.istio-system.svc
export XDS_ROOT_CA=/var/run/secrets/istio/root-cert.pem
export CA_ROOT_CA=/var/run/secrets/istio/root-cert.pem
export ISTIO_META_CLUSTER_ID=rocks-cluster
export CLUSTER_ID=rocks-cluster
export ISTIO_META_ENABLE_HBONE=true
export ISTIO_META_DNS_CAPTURE=true
export ISTIO_META_DNS_AUTO_ALLOCATE=true
export ISTIO_META_DNS_PROXY_ADDR=127.0.0.1:15053
export RUST_LOG=info

ztunnel_exec
