#!/usr/bin/env bash
# Redirect ms-c egress TCP to ztunnel outbound listener (:15001) on the VSI host.
set -euo pipefail

CHAIN=OSM_ZTUNNEL_OUT
MARK_COMMENT="osm-poc-ztunnel-redirect"
# Fixed UID for native ms-c (see /etc/osm-poc/ms-c.env).
MS_C_UID="${MS_C_UID:-185}"
SERVICE_CIDR="${SERVICE_CIDR:-172.21.0.0/16}"
ZTUNNEL_PORTS="15001,15006,15008,15012,15017,15053,15000,15020,15021"

if [[ -f /etc/istio/service-cidr.env ]]; then
  # shellcheck source=/dev/null
  source /etc/istio/service-cidr.env
fi
if [[ -f /etc/osm-poc/ms-c.env ]]; then
  # shellcheck source=/dev/null
  source /etc/osm-poc/ms-c.env
fi

if ! command -v iptables &>/dev/null; then
  echo "ERROR: iptables not found" >&2
  exit 1
fi

if ! systemctl is-active --quiet ztunnel; then
  echo "ERROR: ztunnel.service is not active — start it before redirect setup" >&2
  exit 1
fi

sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || true
if [[ -d /etc/sysctl.d ]]; then
  echo 'net.ipv4.conf.all.route_localnet = 1' >/etc/sysctl.d/99-osm-ztunnel-redirect.conf
fi

echo "==> Installing iptables redirect: uid ${MS_C_UID} -> :15001 (service CIDR ${SERVICE_CIDR})"

iptables -t nat -N "${CHAIN}" 2>/dev/null || iptables -t nat -F "${CHAIN}"

iptables -t nat -A "${CHAIN}" -m comment --comment "${MARK_COMMENT}" -p tcp -m multiport --dports "${ZTUNNEL_PORTS}" -j RETURN
iptables -t nat -A "${CHAIN}" -m comment --comment "${MARK_COMMENT}" -p tcp -d 127.0.0.0/8 -j RETURN
iptables -t nat -A "${CHAIN}" -m comment --comment "${MARK_COMMENT}" -p tcp -m owner --uid-owner "${MS_C_UID}" -d "${SERVICE_CIDR}" -j REDIRECT --to-ports 15001

if ! iptables -t nat -C OUTPUT -m comment --comment "${MARK_COMMENT}" -j "${CHAIN}" 2>/dev/null; then
  while iptables -t nat -D OUTPUT -m comment --comment "${MARK_COMMENT}" -j "${CHAIN}" 2>/dev/null; do :; done
  iptables -t nat -I OUTPUT 1 -m comment --comment "${MARK_COMMENT}" -j "${CHAIN}"
fi

if ! iptables -t nat -S "${CHAIN}" | grep -q 'REDIRECT.*15001'; then
  echo "ERROR: redirect rule missing in chain ${CHAIN}" >&2
  iptables -t nat -S "${CHAIN}" >&2 || true
  exit 1
fi

echo "OK: outbound capture active (iptables -t nat -S ${CHAIN})"
