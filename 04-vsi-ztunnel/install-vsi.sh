#!/usr/bin/env bash
# Workstation helper: build artifacts, generate onboarding, copy to VSI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

: "${VSI_PRIVATE_IP:?}"
: "${VSI_PUBLIC_IP:?}"
: "${EW_GATEWAY_HOST:?}"
: "${SSH_KEY:?Set SSH_KEY to your .prv file}"
: "${SSH_USER:=vpcuser}"

"${ROOT}/package-ms-c-jar.sh"
"${ROOT}/fetch-ztunnel-binary.sh"
"${ROOT}/generate-vsi-onboarding.sh"

echo "==> Copying scripts, binaries, and onboarding to ${SSH_USER}@${VSI_PUBLIC_IP}"
scp -i "${SSH_KEY}" -r \
  "${ROOT}/scripts/install-ztunnel.sh" \
  "${ROOT}/scripts/start-ztunnel.sh" \
  "${ROOT}/scripts/setup-ztunnel-redirect.sh" \
  "${ROOT}/scripts/verify-ztunnel.sh" \
  "${ROOT}/scripts/run-ms-c.sh" \
  "${ROOT}/vsi-onboarding" \
  "${SSH_USER}@${VSI_PUBLIC_IP}:/home/${SSH_USER}/"

cat <<EOF

==> On the VSI (as ${SSH_USER}):
  cd ~
  export EW_GATEWAY_HOST=${EW_GATEWAY_HOST}
  export ISTIOD_GATEWAY_HOST=\${ISTIOD_GATEWAY_HOST:-$(oc -n istio-system get svc istiod-xds-external -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "${EW_GATEWAY_HOST}")}
  sudo -E ./install-ztunnel.sh
  sudo systemctl enable --now ztunnel
  sudo systemctl start ztunnel-dns-forward
  sudo -E MS_A_URL=http://ms-a.osm-poc-demo.svc.cluster.local:8080 ./run-ms-c.sh
  sudo verify-ztunnel.sh

==> From the cluster:
  oc -n osm-poc-demo exec deploy/ms-b -- curl -sf http://ms-c:8080/api/handle-from-b
EOF
