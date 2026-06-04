#!/usr/bin/env bash
# Apply ambient east-west Gateway API resources and the istio-remote network reference.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

echo "==> Removing legacy sidecar east-west gateway (if present)"
oc -n istio-system delete deploy,svc -l istio=eastwestgateway --ignore-not-found
oc -n istio-system delete gateway.gateway.networking.k8s.io istio-eastwestgateway-ambient --ignore-not-found

echo "==> Applying Gateway API ambient east-west gateway"
oc apply -f 04-eastwest-gateway.yaml

echo "==> Waiting for istio-eastwestgateway LoadBalancer hostname"
for _ in $(seq 1 60); do
  EW_GATEWAY_HOST="$(oc -n istio-system get svc istio-eastwestgateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "${EW_GATEWAY_HOST}" ]]; then
    break
  fi
  sleep 5
done
: "${EW_GATEWAY_HOST:?istio-eastwestgateway has no LoadBalancer hostname yet}"

export EW_GATEWAY_HOST
echo "==> EW_GATEWAY_HOST=${EW_GATEWAY_HOST}"

echo "==> Applying istio-remote network reference (ztunnel network_gateway)"
envsubst '${EW_GATEWAY_HOST}' < 04-eastwest-network-ref.yaml | oc apply -f -

oc -n istio-system get gateway.gateway.networking.k8s.io,svc istio-eastwestgateway
echo "==> Done. Record EW_GATEWAY_HOST for VSI onboarding."
