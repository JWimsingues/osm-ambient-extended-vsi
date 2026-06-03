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
  [[ -f "${ONBOARD_DIR}/mesh.yaml" ]] && cp "${ONBOARD_DIR}/mesh.yaml" /etc/istio/config/mesh
  [[ -f "${ONBOARD_DIR}/cluster.env" ]] && cp "${ONBOARD_DIR}/cluster.env" /var/lib/istio/ztunnel/cluster.env
fi

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

echo "==> Installing systemd unit (podman, host network)"
cat >/etc/systemd/system/ztunnel.service <<EOF
[Unit]
Description=Istio ztunnel (ambient) for OSM PoC
After=network-online.target
Wants=network-online.target

[Service]
Environment=ZTUNNEL_IMAGE=${ZTUNNEL_IMAGE}
Environment=PROXY_MODE=dedicated
Environment=PROXY_WORKLOAD_INFO=${PROXY_WORKLOAD_INFO}
Environment=NETWORK=vsi-network
Environment=CA_ADDRESS=istiod.istio-system.svc:15012
Environment=XDS_ADDRESS=istiod.istio-system.svc:15012
Environment=ISTIO_META_CLUSTER_ID=rocks-cluster
Environment=CLUSTER_ID=rocks-cluster
Environment=ISTIO_META_ENABLE_HBONE=true
Environment=ISTIO_META_DNS_CAPTURE=true
Environment=ISTIO_META_DNS_AUTO_ALLOCATE=true
Environment=ISTIO_META_DNS_PROXY_ADDR=127.0.0.1:15053
Environment=RUST_LOG=info
ExecStartPre=-/usr/bin/podman rm -f ztunnel
ExecStart=/usr/bin/podman run --rm --name ztunnel \\
  --network host \\
  --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_ADMIN \\
  -v /var/lib/istio:/var/lib/istio \\
  -v /var/run/secrets/tokens:/var/run/secrets/tokens \\
  -v /var/run/secrets/istio:/var/run/secrets/istio \\
  -v /etc/certs:/etc/certs \\
  -v /etc/istio/config:/etc/istio/config \\
  -v /etc/istio/proxy:/etc/istio/proxy \\
  -v /etc/hosts:/etc/hosts:ro \\
  --add-host istiod.istio-system.svc:${EW_GATEWAY_IP} \\
  --add-host istiod.istio-system.svc.cluster.local:${EW_GATEWAY_IP} \\
  -e PROXY_MODE=dedicated \\
  -e PROXY_WORKLOAD_INFO=${PROXY_WORKLOAD_INFO} \\
  -e NETWORK=vsi-network \\
  -e CA_ADDRESS=istiod.istio-system.svc:15012 \\
  -e XDS_ADDRESS=istiod.istio-system.svc:15012 \\
  -e XDS_ROOT_CA=/var/run/secrets/istio/root-cert.pem \\
  -e CA_ROOT_CA=/var/run/secrets/istio/root-cert.pem \\
  -e ISTIO_META_CLUSTER_ID=rocks-cluster \\
  -e CLUSTER_ID=rocks-cluster \\
  -e ISTIO_META_ENABLE_HBONE=true \\
  -e ISTIO_META_DNS_CAPTURE=true \\
  -e ISTIO_META_DNS_AUTO_ALLOCATE=true \\
  -e ISTIO_META_DNS_PROXY_ADDR=127.0.0.1:15053 \\
  -e RUST_LOG=info \\
  \${ZTUNNEL_IMAGE}
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

systemctl daemon-reload
systemctl enable ztunnel-dns-forward.service
echo "Run: systemctl enable --now ztunnel && systemctl start ztunnel-dns-forward"
echo "Verify: getent hosts ms-a.osm-poc-demo.svc.cluster.local"
