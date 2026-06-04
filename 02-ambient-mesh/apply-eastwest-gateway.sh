#!/usr/bin/env bash
# Deploy the east-west gateway (sidecar-injected Deployment + LoadBalancer Service).
# Idempotent — safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

echo "==> Applying east-west gateway (Deployment + Service)"
oc apply -f 04-eastwest-gateway.yaml

echo "==> Waiting for istio-eastwestgateway LoadBalancer hostname (up to 5 min)"
for _ in $(seq 1 60); do
  EW_GATEWAY_HOST="$(oc -n istio-system get svc istio-eastwestgateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "${EW_GATEWAY_HOST}" ]]; then
    break
  fi
  sleep 5
done
: "${EW_GATEWAY_HOST:?istio-eastwestgateway has no LoadBalancer hostname after 5 min}"

echo "==> EW_GATEWAY_HOST=${EW_GATEWAY_HOST}"
oc -n istio-system get deploy,svc istio-eastwestgateway
echo "==> Done. Record EW_GATEWAY_HOST for VSI onboarding (step 4)."
