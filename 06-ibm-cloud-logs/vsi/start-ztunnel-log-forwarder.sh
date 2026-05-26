#!/usr/bin/env bash
# Optional: forward ztunnel journal logs to /var/log/osm-poc/ztunnel.log for IBM Cloud Logs.
set -euo pipefail

LOG_DIR="${LOG_DIR:-/var/log/osm-poc}"
mkdir -p "${LOG_DIR}"
touch "${LOG_DIR}/ztunnel.log"

if [[ -f /var/run/ztunnel-log-forwarder.pid ]]; then
  kill "$(cat /var/run/ztunnel-log-forwarder.pid)" 2>/dev/null || true
fi

nohup journalctl -u ztunnel -f --no-pager >>"${LOG_DIR}/ztunnel.log" 2>&1 &
echo $! >/var/run/ztunnel-log-forwarder.pid
echo "ztunnel logs -> ${LOG_DIR}/ztunnel.log"
