#!/usr/bin/env bash
# Install and configure ztunnel on IBM Cloud VSI for OSM ambient mesh.
set -euo pipefail

EW_GATEWAY_CONFIG=/etc/istio/ew-gateway.env
: "${ONBOARD_DIR:=/home/vpcuser/vsi-onboarding}"
if [[ -f "${ONBOARD_DIR}/ew-gateway.env" ]]; then
  # shellcheck source=/dev/null
  source "${ONBOARD_DIR}/ew-gateway.env"
fi

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

: "${ISTIOD_GATEWAY_HOST:=${EW_GATEWAY_HOST}}"
export EW_GATEWAY_HOST ISTIOD_GATEWAY_HOST ISTIOD_GATEWAY_IP
install -d -m 0755 /etc/istio
write_ew_gateway_env() {
  cat >"${EW_GATEWAY_CONFIG}" <<EOF
EW_GATEWAY_HOST=${EW_GATEWAY_HOST}
EW_GATEWAY_IP=${EW_GATEWAY_IP:-}
ISTIOD_GATEWAY_HOST=${ISTIOD_GATEWAY_HOST}
ISTIOD_GATEWAY_IP=${ISTIOD_GATEWAY_IP:-}
EOF
  chmod 0644 "${EW_GATEWAY_CONFIG}"
}
write_ew_gateway_env
echo "==> EW_GATEWAY_HOST=${EW_GATEWAY_HOST} (HBONE / meshNetworks)"
echo "==> ISTIOD_GATEWAY_HOST=${ISTIOD_GATEWAY_HOST} (xDS/CA, saved in ${EW_GATEWAY_CONFIG})"
[[ -n "${ISTIOD_GATEWAY_IP:-}" ]] && echo "==> ISTIOD_GATEWAY_IP=${ISTIOD_GATEWAY_IP}"
# Align with OSM 3.3 / Istio 1.28.6 (accept "1.28.6" or "v1.28.6").
: "${ZTUNNEL_VERSION:=1.28.6}"
: "${ZTUNNEL_BIN:=/usr/local/bin/ztunnel}"
# Must match WorkloadEntry metadata.name (see 03-deploy-microservices/05-workload-c.yaml).
: "${PROXY_WORKLOAD_NAME:=ms-c-vsi}"
PROXY_WORKLOAD_INFO="osm-poc-demo/${PROXY_WORKLOAD_NAME}/ms-c"
: "${MS_C_JAR_SRC:=${ONBOARD_DIR}/ms-c-1.0.0-SNAPSHOT.jar}"

echo "==> Installing packages (no podman — native ztunnel + JAR)"
dnf install -y iptables socat java-21-openjdk-headless 2>/dev/null || true

echo "==> Creating istio-proxy user and directories"
groupadd --system istio-proxy 2>/dev/null || true
id istio-proxy &>/dev/null || useradd --system -g istio-proxy -d /var/lib/istio istio-proxy

install -d -m 0750 -o istio-proxy -g istio-proxy \
  /var/lib/istio/ztunnel \
  /var/run/secrets/tokens \
  /var/run/secrets/istio \
  /etc/certs \
  /etc/istio/config \
  /etc/istio/proxy \
  /opt/osm-poc \
  /etc/osm-poc

ZTUNNEL_SRC="${ONBOARD_DIR}/ztunnel"
ZTUNNEL_LIBS_SRC="${ONBOARD_DIR}/ztunnel-libs"
if [[ -f "${ZTUNNEL_SRC}" ]]; then
  echo "==> Installing native ztunnel from ${ZTUNNEL_SRC}"
  install -m 0755 -o root -g root "${ZTUNNEL_SRC}" "${ZTUNNEL_BIN}"
  if [[ -d "${ZTUNNEL_LIBS_SRC}/usr/lib/x86_64-linux-gnu" ]]; then
    echo "==> Installing ztunnel runtime libs (bundled GLIBC from image)"
    rm -rf /opt/istio/ztunnel-libs
    mkdir -p /opt/istio
    cp -a "${ZTUNNEL_LIBS_SRC}" /opt/istio/ztunnel-libs
  fi
  _ld="/opt/istio/ztunnel-libs/usr/lib64/ld-linux-x86-64.so.2"
  _lib="/opt/istio/ztunnel-libs/usr/lib/x86_64-linux-gnu"
  if [[ -f "${_ld}" && -f "${_lib}/libc.so.6" ]]; then
    _run=("${_ld}" --library-path "${_lib}" "${ZTUNNEL_BIN}" version)
  else
    _run=("${ZTUNNEL_BIN}" version)
  fi
  if ! runuser -u istio-proxy -- "${_run[@]}" &>/dev/null; then
    echo "ERROR: ${ZTUNNEL_BIN} failed to run on this host." >&2
    echo "       Re-run ./fetch-ztunnel-binary.sh on the workstation and copy vsi-onboarding/ again." >&2
    exit 1
  fi
  echo "==> $(runuser -u istio-proxy -- "${_run[@]}" 2>/dev/null | head -1)"
else
  echo "ERROR: ${ZTUNNEL_SRC} missing — on workstation run:" >&2
  echo "  ./fetch-ztunnel-binary.sh && scp vsi-onboarding/ztunnel to the VSI" >&2
  exit 1
fi

if [[ -f "${MS_C_JAR_SRC}" ]]; then
  install -m 0644 "${MS_C_JAR_SRC}" /opt/osm-poc/ms-c.jar
  echo "==> Installed ms-c JAR at /opt/osm-poc/ms-c.jar"
else
  echo "WARN: ${MS_C_JAR_SRC} missing — run package-ms-c-jar.sh on workstation before install" >&2
fi

# Retire container-based PoC services if present.
systemctl stop ms-c.service 2>/dev/null || true
if command -v podman &>/dev/null; then
  podman rm -f ms-c ztunnel 2>/dev/null || true
fi

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
  if [[ -f "${ONBOARD_DIR}/ew-gateway.env" ]]; then
    # shellcheck source=/dev/null
    source "${ONBOARD_DIR}/ew-gateway.env"
    write_ew_gateway_env
  fi
fi

SCRIPT_SRC="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${SCRIPT_SRC}")"
# When re-run from /usr/local/bin, helper scripts live next to the copy in /home/vpcuser.
HELPER_DIR="${SCRIPT_DIR}"
if [[ "${SCRIPT_DIR}" == /usr/local/bin && -f /home/vpcuser/start-ztunnel.sh ]]; then
  HELPER_DIR=/home/vpcuser
fi
for helper in setup-ztunnel-redirect.sh verify-ztunnel.sh start-ztunnel.sh; do
  [[ -f "${HELPER_DIR}/${helper}" ]] && install -m 0755 "${HELPER_DIR}/${helper}" "/usr/local/bin/${helper}"
done

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

echo "==> Mapping istiod and east-west gateways in /etc/hosts"
if [[ -n "${ISTIOD_GATEWAY_IP:-}" ]]; then
  ISTIOD_IP="${ISTIOD_GATEWAY_IP}"
elif [[ "${ISTIOD_GATEWAY_HOST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  ISTIOD_IP="${ISTIOD_GATEWAY_HOST}"
else
  ISTIOD_IP="$(getent ahostsv4 "${ISTIOD_GATEWAY_HOST}" 2>/dev/null | awk '{print $1; exit}' || true)"
  if [[ -z "${ISTIOD_IP}" ]]; then
    echo "ERROR: cannot resolve ISTIOD_GATEWAY_HOST=${ISTIOD_GATEWAY_HOST} (set ISTIOD_GATEWAY_IP in onboarding ew-gateway.env)" >&2
    exit 1
  fi
fi
echo "    ${ISTIOD_GATEWAY_HOST} -> ${ISTIOD_IP}"
if [[ -n "${EW_GATEWAY_IP:-}" ]]; then
  EW_IP="${EW_GATEWAY_IP}"
elif [[ -n "${EW_GATEWAY_HOST:-}" ]]; then
  if [[ "${EW_GATEWAY_HOST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    EW_IP="${EW_GATEWAY_HOST}"
  else
    EW_IP="$(getent ahostsv4 "${EW_GATEWAY_HOST}" 2>/dev/null | awk '{print $1; exit}' || true)"
  fi
  [[ -n "${EW_IP:-}" ]] && echo "    ${EW_GATEWAY_HOST} -> ${EW_IP} (east-west HBONE)"
fi
ISTIOD_GATEWAY_IP="${ISTIOD_IP}"
EW_GATEWAY_IP="${EW_IP:-}"
write_ew_gateway_env
grep -v -E 'istiod\.istio-system\.svc|istio-eastwestgateway\.istio-system\.svc' /etc/hosts > /etc/hosts.tmp || true
mv /etc/hosts.tmp /etc/hosts
cat >>/etc/hosts <<HOSTS
${ISTIOD_IP} istiod.istio-system.svc istiod.istio-system.svc.cluster.local
HOSTS
if [[ -n "${EW_IP:-}" ]]; then
  cat >>/etc/hosts <<HOSTS
${EW_IP} istio-eastwestgateway.istio-system.svc istio-eastwestgateway.istio-system.svc.cluster.local
HOSTS
  if [[ -n "${EW_GATEWAY_HOST:-}" && "${EW_GATEWAY_HOST}" != "${EW_IP}" ]]; then
    cat >>/etc/hosts <<HOSTS
${EW_IP} ${EW_GATEWAY_HOST}
HOSTS
  fi
fi

chown -R istio-proxy:istio-proxy /var/lib/istio /var/run/secrets /etc/certs /etc/istio

echo "==> Installing systemd unit (native ztunnel)"
cat >/etc/systemd/system/ztunnel.service <<EOF
[Unit]
Description=Istio ztunnel (ambient, native) for OSM PoC
After=network-online.target
Wants=network-online.target

[Service]
User=istio-proxy
Group=istio-proxy
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_ADMIN
Environment=ZTUNNEL_BIN=${ZTUNNEL_BIN}
Environment=ZTUNNEL_LIBS_ROOT=/opt/istio/ztunnel-libs
Environment=PROXY_WORKLOAD_INFO=${PROXY_WORKLOAD_INFO}
EnvironmentFile=-${EW_GATEWAY_CONFIG}
ExecStart=/usr/local/bin/start-ztunnel.sh
Restart=always
RestartSec=5
LimitNOFILE=65535

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
echo "  sudo ./run-ms-c.sh"
echo "  sudo systemctl start ztunnel-redirect"
echo "  sudo verify-ztunnel.sh"
echo "Mesh egress test (from cluster): oc -n osm-poc-demo exec deploy/ms-b -- curl -sf http://ms-c:8080/api/handle-from-b"

if systemctl is-active --quiet ztunnel 2>/dev/null; then
  echo "==> ztunnel already running — reload units (restart manually if you changed env: systemctl restart ztunnel)"
  systemctl start ztunnel-dns-forward 2>/dev/null || true
  if systemctl is-active --quiet ms-c 2>/dev/null; then
    echo "==> ms-c active — applying outbound redirect"
    /usr/local/bin/setup-ztunnel-redirect.sh || true
    systemctl start ztunnel-redirect 2>/dev/null || true
  fi
fi
