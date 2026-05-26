#!/usr/bin/env bash
# Run ms-c on the VSI (localhost:8080) with JSON logs forwarded for IBM Cloud Logs.
set -euo pipefail

: "${QUAY_ORG:?}"
: "${IMAGE_TAG:=latest}"
: "${MS_A_URL:=http://ms-a.osm-poc-demo.svc.cluster.local:8080}"
: "${LOG_DIR:=/var/log/osm-poc}"

IMAGE="quay.io/${QUAY_ORG}/osm-poc-ms-c:${IMAGE_TAG}"

mkdir -p "${LOG_DIR}"
touch "${LOG_DIR}/ms-c.log"
chmod 644 "${LOG_DIR}/ms-c.log"

podman rm -f ms-c 2>/dev/null || true
podman run -d --name ms-c --restart=always \
  -p 127.0.0.1:8080:8080 \
  -e BIND_HOST=0.0.0.0 \
  -e LOG_FORMAT=json \
  -e MS_A_URL="${MS_A_URL}" \
  "${IMAGE}"

# Forward container stdout to a file tailed by Fluent Bit on the VSI
if [[ -f /var/run/ms-c-log-forwarder.pid ]]; then
  kill "$(cat /var/run/ms-c-log-forwarder.pid)" 2>/dev/null || true
fi
nohup podman logs -f ms-c >>"${LOG_DIR}/ms-c.log" 2>&1 &
echo $! >/var/run/ms-c-log-forwarder.pid

echo "ms-c listening on http://127.0.0.1:8080"
echo "JSON logs appended to ${LOG_DIR}/ms-c.log (IBM Cloud Logs agent tails this file)"
echo "Follow locally: tail -f ${LOG_DIR}/ms-c.log"
