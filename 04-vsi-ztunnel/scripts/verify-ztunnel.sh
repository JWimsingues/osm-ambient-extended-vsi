#!/usr/bin/env bash
# Post-install checks for ztunnel + ms-c on the VSI.
set -euo pipefail

fail=0
ok() { echo "OK: $*"; }
err() { echo "ERROR: $*" >&2; fail=1; }
warn() { echo "WARN: $*" >&2; }

if systemctl is-active --quiet ztunnel; then
  ok "ztunnel.service active"
else
  err "ztunnel.service not active"
fi

# Readiness returns 500 until xDS syncs; wait and accept /healthz/ready 200.
xds_ready=0
for _ in $(seq 1 45); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:15021/healthz/ready 2>/dev/null || echo 000)"
  if [[ "${code}" == "200" ]]; then
    xds_ready=1
    break
  fi
  sleep 2
done
if [[ "${xds_ready}" -eq 1 ]]; then
  ok "ztunnel xDS ready (:15021/healthz/ready)"
elif curl -sf --max-time 3 http://127.0.0.1:15000/config_dump 2>/dev/null | grep -q '"status": "Healthy"'; then
  ok "ztunnel config_dump shows Healthy workloads (readiness HTTP not 200 yet)"
else
  err "ztunnel not ready — check: journalctl -u ztunnel | grep -i xds; ensure /etc/hosts istiod IP matches current east-west LB (re-run install-ztunnel.sh)"
  sudo podman logs ztunnel 2>&1 | grep -iE 'xds|ready|error' | tail -5 >&2 || true
fi

EW_GATEWAY_CONFIG=/etc/istio/ew-gateway.env
if [[ -f "${EW_GATEWAY_CONFIG}" ]]; then
  # shellcheck source=/dev/null
  source "${EW_GATEWAY_CONFIG}"
  istiod_host="${ISTIOD_GATEWAY_HOST:-${EW_GATEWAY_HOST:-}}"
  if [[ -n "${istiod_host}" ]]; then
    if [[ "${istiod_host}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      expected_ip="${istiod_host}"
    else
      expected_ip="$(getent ahostsv4 "${istiod_host}" | awk '{print $1; exit}')"
    fi
    hosts_ip="$(getent hosts istiod.istio-system.svc | awk '{print $1; exit}')"
    if [[ -n "${expected_ip}" && -n "${hosts_ip}" && "${expected_ip}" == "${hosts_ip}" ]]; then
      ok "istiod /etc/hosts -> ${hosts_ip} (matches ${istiod_host})"
    else
      err "istiod /etc/hosts (${hosts_ip:-missing}) != resolved istiod LB IP (${expected_ip:-missing}) — sudo systemctl restart ztunnel"
    fi
  fi
fi

if systemctl is-active --quiet ztunnel-dns-forward 2>/dev/null; then
  ok "ztunnel-dns-forward active"
else
  warn "ztunnel-dns-forward not active (mesh DNS may fail until started)"
fi

if getent hosts ms-a.osm-poc-demo.svc.cluster.local >/dev/null 2>&1; then
  ok "mesh DNS ms-a -> $(getent hosts ms-a.osm-poc-demo.svc.cluster.local | awk '{print $1}')"
else
  err "mesh DNS lookup failed — start: sudo systemctl start ztunnel-dns-forward"
fi

if grep -q 'PROXY_WORKLOAD_INFO=osm-poc-demo/ms-c-vsi/ms-c' /etc/systemd/system/ztunnel.service 2>/dev/null \
  || grep -q 'ms-c-vsi' /usr/local/bin/start-ztunnel.sh 2>/dev/null; then
  ok "PROXY_WORKLOAD_INFO matches WorkloadEntry ms-c-vsi"
else
  err "PROXY_WORKLOAD_INFO mismatch"
fi

if iptables -t nat -S OSM_ZTUNNEL_OUT 2>/dev/null | grep -q 'REDIRECT.*15001'; then
  ok "iptables outbound redirect to :15001"
else
  err "iptables chain OSM_ZTUNNEL_OUT missing — run: sudo setup-ztunnel-redirect.sh"
fi

if curl -sf --max-time 5 http://127.0.0.1:8080/health >/dev/null 2>&1; then
  ok "ms-c /health"
else
  err "ms-c /health failed"
fi

exit "${fail}"
