#!/usr/bin/env bash
# Install and configure ztunnel on IBM Cloud VSI for OSM ambient mesh.
set -euo pipefail

: "${EW_GATEWAY_HOST:?Set EW_GATEWAY_HOST to the east-west LoadBalancer hostname}"
: "${ZTUNNEL_VERSION:=1.24.2}"
: "${ONBOARD_DIR:=/root/vsi-onboarding}"
: "${ZTUNNEL_BIN_URL:=https://github.com/istio/ztunnel/releases/download/${ZTUNNEL_VERSION}/ztunnel-linux-amd64}"

echo "==> Creating istio-proxy user and directories"
groupadd --system istio-proxy 2>/dev/null || true
id istio-proxy &>/dev/null || useradd --system -g istio-proxy -d /var/lib/istio istio-proxy

install -d -m 0750 -o istio-proxy -g istio-proxy \
  /var/lib/istio/ztunnel \
  /var/run/secrets/tokens \
  /var/run/secrets/istio \
  /etc/certs \
  /etc/istio/config \
  /etc/istio/proxy

echo "==> Downloading ztunnel ${ZTUNNEL_VERSION}"
curl -fsSL "${ZTUNNEL_BIN_URL}" -o /usr/local/bin/ztunnel
chmod 0755 /usr/local/bin/ztunnel

if [[ -d "${ONBOARD_DIR}" ]]; then
  echo "==> Copying onboarding files from ${ONBOARD_DIR}"
  cp -a "${ONBOARD_DIR}/." /var/lib/istio/ztunnel/
  [[ -f "${ONBOARD_DIR}/root-cert.pem" ]] && cp "${ONBOARD_DIR}/root-cert.pem" /etc/certs/root-cert.pem
  [[ -f "${ONBOARD_DIR}/istio-token" ]] && cp "${ONBOARD_DIR}/istio-token" /var/run/secrets/tokens/istio-token
  [[ -f "${ONBOARD_DIR}/mesh.yaml" ]] && cp "${ONBOARD_DIR}/mesh.yaml" /etc/istio/config/mesh
  [[ -f "${ONBOARD_DIR}/cluster.env" ]] && cp "${ONBOARD_DIR}/cluster.env" /var/lib/istio/ztunnel/cluster.env
fi

echo "==> Mapping istiod to east-west gateway"
grep -q 'istiod.istio-system.svc' /etc/hosts || \
  echo "${EW_GATEWAY_HOST} istiod.istio-system.svc" >> /etc/hosts

chown -R istio-proxy:istio-proxy /var/lib/istio /var/run/secrets /etc/certs /etc/istio

echo "==> Installing systemd unit"
cat >/etc/systemd/system/ztunnel.service <<EOF
[Unit]
Description=Istio ztunnel (ambient) for OSM PoC
After=network-online.target
Wants=network-online.target

[Service]
User=istio-proxy
Group=istio-proxy
Environment=PROXY_MODE=dedicated
Environment=CA_ADDRESS=istiod.istio-system.svc:15012
Environment=XDS_ADDRESS=istiod.istio-system.svc:15012
Environment=CLUSTER_ID=rocks-cluster
Environment=ISTIO_META_ENABLE_HBONE=true
Environment=ISTIO_META_DNS_CAPTURE=true
Environment=ISTIO_META_DNS_AUTO_ALLOCATE=true
Environment=ISTIO_META_DNS_PROXY_ADDR=127.0.0.1:15053
Environment=RUST_LOG=info
ExecStart=/usr/local/bin/ztunnel
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
echo "Run: systemctl enable --now ztunnel"
