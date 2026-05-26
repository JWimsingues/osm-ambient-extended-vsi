#!/usr/bin/env bash
# Install IBM Cloud Logs Fluent Bit agent on RHEL 9 VSI (systemd).
# Run as root on the VSI. Requires INGESTION_HOST, INGESTION_PORT, IAM_API_KEY.
set -euo pipefail

: "${INGESTION_HOST:?Set INGESTION_HOST, e.g. <guid>.ingress.eu-de.logs.cloud.ibm.com}"
: "${INGESTION_PORT:=443}"
: "${IAM_API_KEY:?Set IAM_API_KEY (Service ID with Sender role)}"
: "${CLUSTER_NAME:=vsi-osm-poc}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DST="/etc/fluent-bit/fluent-bit.conf"
INCLUDE_DST="/etc/fluent-bit/osm-poc-ms-c.conf"

echo "==> Installing fluent-bit (RHEL 9)"
dnf install -y fluent-bit || {
  curl -fsSL https://raw.githubusercontent.com/fluent/fluent-bit/master/install.sh | sh
}

mkdir -p /var/log/osm-poc /etc/fluent-bit

if [[ -f "${SCRIPT_DIR}/fluent-bit-ms-c.conf" ]]; then
  cp "${SCRIPT_DIR}/fluent-bit-ms-c.conf" "${INCLUDE_DST}"
else
  cp "${SCRIPT_DIR}/fluent-bit-ms-c.conf.template" "${INCLUDE_DST}"
  sed -i "s|\${INGESTION_HOST}|${INGESTION_HOST}|g" "${INCLUDE_DST}"
  sed -i "s|\${INGESTION_PORT}|${INGESTION_PORT}|g" "${INCLUDE_DST}"
  sed -i "s|\${IAM_API_KEY}|${IAM_API_KEY}|g" "${INCLUDE_DST}"
  sed -i "s|\${CLUSTER_NAME}|${CLUSTER_NAME}|g" "${INCLUDE_DST}"
fi

cat >"${CONF_DST}" <<EOF
[SERVICE]
    Flush        5
    Daemon       Off
    Log_Level    info
    Parsers_File /etc/fluent-bit/parsers.conf

@INCLUDE ${INCLUDE_DST}
EOF

cat >/etc/sysconfig/fluent-bit <<EOF
IAM_API_KEY=${IAM_API_KEY}
INGESTION_HOST=${INGESTION_HOST}
INGESTION_PORT=${INGESTION_PORT}
EOF

systemctl enable fluent-bit
systemctl restart fluent-bit
systemctl status fluent-bit --no-pager

echo "Agent running. Tail: journalctl -u fluent-bit -f"
