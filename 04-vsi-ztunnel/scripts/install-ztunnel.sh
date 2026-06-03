#!/usr/bin/env bash
# Install and configure ztunnel on IBM Cloud VSI for OSM ambient mesh.
set -euo pipefail

EW_GATEWAY_CONFIG=/etc/istio/ew-gateway.env

if [[ -z "${EW_GATEWAY_HOST:-}" ]]; then
  if [[ -n "${1:-}" ]]; then
    EW_GATEWAY_HOST="$1"
  elif [[ -f "${EW_GATEWAY_CONFIG}" ]]; then
    # shellcheck source=/dev/null
    source "${EW_GATEWAY_CONFIG}"
  fi
fi

if [[ -z "${EW_GATEWAY_HOST:-}" ]]; then
  cat >&2 <<'EOF'
ERROR: EW_GATEWAY_HOST is not set (east-west LoadBalancer hostname from the cluster).

On the cluster:
  oc -n istio-system get svc istio-eastwestgateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'

On the VSI, use one of:
  export EW_GATEWAY_HOST="<hostname>"
  sudo -E ./install-ztunnel.sh

  ./install-ztunnel.sh <hostname>
  sudo ./install-ztunnel.sh <hostname>
EOF
  exit 1
fi

export EW_GATEWAY_HOST
install -d -m 0755 /etc/istio
printf 'EW_GATEWAY_HOST=%q\n' "${EW_GATEWAY_HOST}" >"${EW_GATEWAY_CONFIG}"
chmod 0644 "${EW_GATEWAY_CONFIG}"
echo "==> Using EW_GATEWAY_HOST=${EW_GATEWAY_HOST} (saved in ${EW_GATEWAY_CONFIG})"
# Align with OSM 3.3 / Istio 1.28.6 (accept "1.28.6" or "v1.28.6").
: "${ZTUNNEL_VERSION:=1.28.6}"
: "${ONBOARD_DIR:=/home/vpcuser/vsi-onboarding}"
# Must match WorkloadEntry metadata.name (see 03-deploy-microservices/05-workload-c.yaml).
: "${PROXY_WORKLOAD_NAME:=ms-c-vsi}"
PROXY_WORKLOAD_INFO="osm-poc-demo/${PROXY_WORKLOAD_NAME}/ms-c"
ZTUNNEL_IMAGE_TAG="${ZTUNNEL_VERSION#v}"
: "${ZTUNNEL_IMAGE:=docker.io/istio/ztunnel:${ZTUNNEL_IMAGE_TAG}}"

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

echo "==> Pulling ztunnel ${ZTUNNEL_IMAGE_TAG} from ${ZTUNNEL_IMAGE}"
# Run ztunnel in the official image (do not copy the binary to the host). The image is built
# with a newer glibc than many IBM Cloud RHEL 9 VSIs provide; extracting /usr/local/bin/ztunnel
# fails at runtime with "GLIBC_2.38 not found".
podman pull "${ZTUNNEL_IMAGE}"

if [[ -d "${ONBOARD_DIR}" ]]; then
  echo "==> Copying onboarding files from ${ONBOARD_DIR}"
  cp -a "${ONBOARD_DIR}/." /var/lib/istio/ztunnel/
  if [[ -f "${ONBOARD_DIR}/root-cert.pem" ]]; then
    # ztunnel defaults: XDS_ROOT_CA and CA_ROOT_CA -> ./var/run/secrets/istio/root-cert.pem
    cp "${ONBOARD_DIR}/root-cert.pem" /var/run/secrets/istio/root-cert.pem
    cp "${ONBOARD_DIR}/root-cert.pem" /etc/certs/root-cert.pem
  fi
  [[ -f "${ONBOARD_DIR}/istio-token" ]] && cp "${ONBOARD_DIR}/istio-token" /var/run/secrets/tokens/istio-token
  if [[ -f "${ONBOARD_DIR}/mesh.yaml" ]]; then
    cp "${ONBOARD_DIR}/mesh.yaml" /etc/istio/config/mesh
    sed -i 's/ISTIO_META_NETWORK: ""/ISTIO_META_NETWORK: "vsi-network"/' /etc/istio/config/mesh
    sed -i 's/SERVICE_ACCOUNT: default/SERVICE_ACCOUNT: ms-c/' /etc/istio/config/mesh
  fi
  if [[ -f "${ONBOARD_DIR}/cluster.env" ]]; then
    cp "${ONBOARD_DIR}/cluster.env" /var/lib/istio/ztunnel/cluster.env
    sed -i "s/ISTIO_META_NETWORK=''/ISTIO_META_NETWORK='vsi-network'/" /var/lib/istio/ztunnel/cluster.env
    sed -i "s/SERVICE_ACCOUNT='default'/SERVICE_ACCOUNT='ms-c'/" /var/lib/istio/ztunnel/cluster.env
  fi
  if [[ -f "${ONBOARD_DIR}/hosts" ]]; then
    grep -v 'istiod\.istio-system\.svc' /etc/hosts > /etc/hosts.tmp || true
    mv /etc/hosts.tmp /etc/hosts
    cat "${ONBOARD_DIR}/hosts" >>/etc/hosts
    grep -q 'istiod.istio-system.svc.cluster.local' /etc/hosts || \
      sed 's/istiod\.istio-system\.svc$/& istiod.istio-system.svc.cluster.local/' -i /etc/hosts
  fi
  if [[ -f "${ONBOARD_DIR}/service.env" ]]; then
    cp "${ONBOARD_DIR}/service.env" /etc/istio/service-cidr.env
  fi
fi

SCRIPT_SRC="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${SCRIPT_SRC}")"
install -m 0755 "${SCRIPT_DIR}/setup-ztunnel-redirect.sh" /usr/local/bin/setup-ztunnel-redirect.sh
install -m 0755 "${SCRIPT_DIR}/verify-ztunnel.sh" /usr/local/bin/verify-ztunnel.sh
install -m 0755 "${SCRIPT_DIR}/start-ztunnel.sh" /usr/local/bin/start-ztunnel.sh

if [[ ! -f /etc/istio/service-cidr.env ]]; then
  echo 'SERVICE_CIDR=172.21.0.0/16' >/etc/istio/service-cidr.env
  echo "WARN: ${ONBOARD_DIR}/service.env missing — using default SERVICE_CIDR=172.21.0.0/16" >&2
  echo "      Regenerate onboarding with generate-vsi-onboarding.sh for your cluster CIDR." >&2
fi
chmod 0644 /etc/istio/service-cidr.env

if [[ ! -f /var/run/secrets/istio/root-cert.pem ]]; then
  cat >&2 <<EOF
ERROR: /var/run/secrets/istio/root-cert.pem is missing (ztunnel needs it to trust istiod on :15012).

On your workstation, regenerate onboarding files:
  istioctl x workload entry configure \\
    -f ../03-deploy-microservices/05-workload-c.yaml \\
    --clusterID rocks-cluster \\
    -o ./vsi-onboarding \\
    --tokenDuration=86400

Or copy the current mesh root from the cluster:
  oc -n istio-system get cm istio-ca-root-cert \\
    -o jsonpath='{.data.root-cert\\.pem}' > root-cert.pem
  scp root-cert.pem vpcuser@<VSI>:/home/vpcuser/vsi-onboarding/

Then re-run this script.
EOF
  exit 1
fi

if [[ ! -f /var/run/secrets/tokens/istio-token ]]; then
  echo "WARN: /var/run/secrets/tokens/istio-token missing — ztunnel may fail after TLS connects" >&2
fi

echo "==> Mapping istiod to east-west gateway (resolve LB hostname to IP for /etc/hosts)"
if [[ "${EW_GATEWAY_HOST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  EW_GATEWAY_IP="${EW_GATEWAY_HOST}"
else
  EW_GATEWAY_IP="$(getent ahostsv4 "${EW_GATEWAY_HOST}" | awk '{print $1; exit}')"
  if [[ -z "${EW_GATEWAY_IP}" ]]; then
    echo "ERROR: cannot resolve EW_GATEWAY_HOST=${EW_GATEWAY_HOST} to an IPv4 address" >&2
    exit 1
  fi
fi
echo "    ${EW_GATEWAY_HOST} -> ${EW_GATEWAY_IP}"
grep -v 'istiod\.istio-system\.svc' /etc/hosts > /etc/hosts.tmp || true
mv /etc/hosts.tmp /etc/hosts
cat >>/etc/hosts <<HOSTS
${EW_GATEWAY_IP} istiod.istio-system.svc istiod.istio-system.svc.cluster.local
HOSTS

chown -R istio-proxy:istio-proxy /var/lib/istio /var/run/secrets /etc/certs /etc/istio

echo "==> Installing systemd unit (start-ztunnel.sh resolves EW LB IP on each start)"
cat >/etc/systemd/system/ztunnel.service <<EOF
[Unit]
Description=Istio ztunnel (ambient) for OSM PoC
After=network-online.target
Wants=network-online.target

[Service]
Environment=ZTUNNEL_IMAGE=${ZTUNNEL_IMAGE}
Environment=PROXY_WORKLOAD_INFO=${PROXY_WORKLOAD_INFO}
ExecStartPre=-/usr/bin/podman rm -f ztunnel
ExecStart=/usr/local/bin/start-ztunnel.sh
ExecStop=/usr/bin/podman stop -t 10 ztunnel
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "==> Configuring mesh DNS for host processes (ztunnel DNS listens on :15053, not :53)"
dnf install -y socat 2>/dev/null || true
cat >/etc/resolv.conf <<'RESOLV'
nameserver 127.0.0.1
search osm-poc-demo.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
RESOLV
chmod 644 /etc/resolv.conf

cat >/etc/systemd/system/ztunnel-dns-forward.service <<'EOF'
[Unit]
Description=Forward local DNS :53 to ztunnel :15053
After=ztunnel.service
Requires=ztunnel.service

[Service]
ExecStart=/usr/bin/socat UDP4-LISTEN:53,bind=127.0.0.1,reuseaddr,fork UDP4:127.0.0.1:15053
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/ztunnel-redirect.service <<'EOF'
[Unit]
Description=Redirect ms-c egress to ztunnel :15001
After=ztunnel.service
Wants=ztunnel.service

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=-/etc/istio/service-cidr.env
ExecStart=/usr/local/bin/setup-ztunnel-redirect.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ztunnel-dns-forward.service ztunnel-redirect.service
echo "Run in order:"
echo "  sudo systemctl enable --now ztunnel"
echo "  sudo systemctl start ztunnel-dns-forward"
echo "  sudo ./run-ms-c.sh   # or podman start ms-c, then:"
echo "  sudo systemctl start ztunnel-redirect"
echo "  sudo verify-ztunnel.sh"
echo "Mesh egress test (from cluster): oc -n osm-poc-demo exec deploy/ms-b -- curl -sf http://ms-c:8080/api/handle-from-b"

if systemctl is-active --quiet ztunnel 2>/dev/null; then
  echo "==> ztunnel already running — reload units (restart manually if you changed env: systemctl restart ztunnel)"
  systemctl start ztunnel-dns-forward 2>/dev/null || true
  if podman container exists ms-c 2>/dev/null; then
    echo "==> ms-c detected — applying outbound redirect"
    /usr/local/bin/setup-ztunnel-redirect.sh || true
    systemctl start ztunnel-redirect 2>/dev/null || true
  fi
fi
