#!/usr/bin/env bash
# Redirect ms-c egress TCP to ztunnel outbound listener (:15001) on the VSI host.
# Required for PROXY_MODE=dedicated on bare metal (no istio-cni in the app netns).
set -euo pipefail

CHAIN=OSM_ZTUNNEL_OUT
MARK_COMMENT="osm-poc-ztunnel-redirect"
MS_C_CONTAINER="${MS_C_CONTAINER:-ms-c}"
# ms-c image runs as UID 185 (see microservices/ms-c/Containerfile).
MS_C_UID="${MS_C_UID:-185}"
# Populated from vsi-onboarding/service.env or cluster network during onboarding.
SERVICE_CIDR="${SERVICE_CIDR:-172.21.0.0/16}"
ZTUNNEL_PORTS="15001,15006,15008,15012,15017,15053,15000,15020,15021"

if [[ -f /etc/istio/service-cidr.env ]]; then
  # shellcheck source=/dev/null
  source /etc/istio/service-cidr.env
fi

if ! command -v iptables &>/dev/null; then
  echo "ERROR: iptables not found" >&2
  exit 1
fi

if ! systemctl is-active --quiet ztunnel; then
  echo "ERROR: ztunnel.service is not active — start it before redirect setup" >&2
  exit 1
fi

# Required for REDIRECT to local ztunnel ports (15001) on the host.
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || true
if [[ -d /etc/sysctl.d ]]; then
  echo 'net.ipv4.conf.all.route_localnet = 1' >/etc/sysctl.d/99-osm-ztunnel-redirect.conf
fi

# Wait for ms-c container (run-ms-c.sh may call this immediately after podman run).
for _ in $(seq 1 30); do
  if podman container exists "${MS_C_CONTAINER}" 2>/dev/null; then
    running_uid="$(podman inspect "${MS_C_CONTAINER}" --format '{{.Config.User}}' 2>/dev/null || true)"
    if [[ -n "${running_uid}" && "${running_uid}" != "0" ]]; then
      MS_C_UID="${running_uid%%:*}"
    fi
    break
  fi
  sleep 2
done

if ! podman container exists "${MS_C_CONTAINER}" 2>/dev/null; then
  echo "WARN: container ${MS_C_CONTAINER} not found — installing redirect for UID ${MS_C_UID} only" >&2
fi

echo "==> Installing iptables redirect: uid ${MS_C_UID} -> :15001 (service CIDR ${SERVICE_CIDR})"

iptables -t nat -N "${CHAIN}" 2>/dev/null || iptables -t nat -F "${CHAIN}"

iptables -t nat -A "${CHAIN}" -m comment --comment "${MARK_COMMENT}" -p tcp -m multiport --dports "${ZTUNNEL_PORTS}" -j RETURN
iptables -t nat -A "${CHAIN}" -m comment --comment "${MARK_COMMENT}" -p tcp -d 127.0.0.0/8 -j RETURN

MS_C_CGROUP=""
if podman container exists "${MS_C_CONTAINER}" 2>/dev/null; then
  MS_C_CGROUP="$(podman inspect "${MS_C_CONTAINER}" --format '{{.State.CgroupPath}}' 2>/dev/null || true)"
fi

if [[ -n "${MS_C_CGROUP}" ]] && iptables -m cgroup -h 2>&1 | grep -q path; then
  iptables -t nat -A "${CHAIN}" -m comment --comment "${MARK_COMMENT}" -p tcp -m cgroup --path "${MS_C_CGROUP}" -d "${SERVICE_CIDR}" -j REDIRECT --to-ports 15001
  echo "    cgroup match: ${MS_C_CGROUP}"
fi

iptables -t nat -A "${CHAIN}" -m comment --comment "${MARK_COMMENT}" -p tcp -m owner --uid-owner "${MS_C_UID}" -d "${SERVICE_CIDR}" -j REDIRECT --to-ports 15001

if ! iptables -t nat -C OUTPUT -m comment --comment "${MARK_COMMENT}" -j "${CHAIN}" 2>/dev/null; then
  # Remove stale jump rules from previous runs.
  while iptables -t nat -D OUTPUT -m comment --comment "${MARK_COMMENT}" -j "${CHAIN}" 2>/dev/null; do :; done
  iptables -t nat -I OUTPUT 1 -m comment --comment "${MARK_COMMENT}" -j "${CHAIN}"
fi

if ! iptables -t nat -S "${CHAIN}" | grep -q 'REDIRECT.*15001'; then
  echo "ERROR: redirect rule missing in chain ${CHAIN}" >&2
  iptables -t nat -S "${CHAIN}" >&2 || true
  exit 1
fi

echo "OK: outbound capture active (iptables -t nat -S ${CHAIN})"
