#!/usr/bin/env bash
# Install and start ms-c as a native JAR (systemd), no containers.
set -euo pipefail

: "${MS_C_JAR:=/opt/osm-poc/ms-c.jar}"
: "${MS_A_URL:=http://ms-a.osm-poc-demo.svc.cluster.local:8080}"
: "${LOG_DIR:=/var/log/osm-poc}"
: "${MS_C_UID:=185}"
: "${MS_C_USER:=ms-c}"

if [[ ! -f "${MS_C_JAR}" ]]; then
  echo "ERROR: ${MS_C_JAR} missing — copy vsi-onboarding/ms-c-*.jar to /opt/osm-poc/ms-c.jar (install-ztunnel.sh does this)" >&2
  exit 1
fi

if ! command -v java &>/dev/null; then
  echo "ERROR: java not found — install: dnf install -y java-21-openjdk-headless" >&2
  exit 1
fi

getent group "${MS_C_USER}" &>/dev/null || groupadd --system "${MS_C_USER}"
if ! id "${MS_C_USER}" &>/dev/null; then
  useradd --system -u "${MS_C_UID}" -g "${MS_C_USER}" -d /var/lib/ms-c -s /sbin/nologin "${MS_C_USER}" 2>/dev/null \
    || useradd --system -g "${MS_C_USER}" -d /var/lib/ms-c -s /sbin/nologin "${MS_C_USER}"
fi

install -d -m 0750 -o "${MS_C_USER}" -g "${MS_C_USER}" /opt/osm-poc /var/lib/ms-c "${LOG_DIR}"
if [[ "$(readlink -f "${MS_C_JAR}")" != "$(readlink -f /opt/osm-poc/ms-c.jar)" ]]; then
  install -m 0640 -o "${MS_C_USER}" -g "${MS_C_USER}" "${MS_C_JAR}" /opt/osm-poc/ms-c.jar
fi
chown "${MS_C_USER}:${MS_C_USER}" /opt/osm-poc/ms-c.jar

cat >/etc/osm-poc/ms-c.env <<EOF
MS_C_UID=${MS_C_UID}
MS_A_URL=${MS_A_URL}
JAVA_OPTS=-Djava.net.preferIPv4Stack=true
EOF
chmod 0644 /etc/osm-poc/ms-c.env

touch "${LOG_DIR}/ms-c.log"
chown "${MS_C_USER}:${MS_C_USER}" "${LOG_DIR}/ms-c.log"

cat >/etc/systemd/system/ms-c.service <<EOF
[Unit]
Description=OSM PoC ms-c (native JAR on VSI)
After=network-online.target ztunnel.service
Wants=network-online.target

[Service]
User=${MS_C_USER}
Group=${MS_C_USER}
EnvironmentFile=/etc/osm-poc/ms-c.env
WorkingDirectory=/var/lib/ms-c
ExecStart=/usr/bin/java \${JAVA_OPTS} -jar /opt/osm-poc/ms-c.jar
StandardOutput=append:${LOG_DIR}/ms-c.log
StandardError=append:${LOG_DIR}/ms-c.log
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ms-c.service
systemctl restart ms-c.service

if systemctl is-active --quiet ztunnel; then
  echo "==> Applying ztunnel outbound redirect for ms-c (uid ${MS_C_UID})"
  REDIRECT=/usr/local/bin/setup-ztunnel-redirect.sh
  [[ -x "${REDIRECT}" ]] || REDIRECT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup-ztunnel-redirect.sh"
  "${REDIRECT}"
  systemctl enable --now ztunnel-redirect.service 2>/dev/null || true
else
  echo "WARN: ztunnel not running — start ztunnel before mesh egress works" >&2
fi

echo "ms-c listening on http://127.0.0.1:8080 (systemctl status ms-c)"
echo "Logs: ${LOG_DIR}/ms-c.log"
