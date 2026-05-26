#!/usr/bin/env bash
# Run the PoC chain with a fixed trace id and print IBM Cloud Logs query hints.
set -euo pipefail

TRACE="${TRACE_ID:-demo-$(date +%Y%m%d-%H%M%S)}"
NS="${NAMESPACE:-osm-poc-demo}"

echo "==> Trace id: ${TRACE}"
echo "==> Calling in-mesh: http://ms-a:8080/api/run-chain"

oc -n "${NS}" run "demo-trace-${TRACE:0:8}" --rm -i --restart=Never \
  --image=curlimages/curl \
  --labels="istio.io/dataplane-mode=ambient" \
  --command -- \
  curl -sf -H "X-Trace-Id: ${TRACE}" "http://ms-a:8080/api/run-chain" | tee /tmp/osm-poc-response.json

echo ""
echo "==> IBM Cloud Logs — paste these queries (Logs viewer):"
echo ""
echo "  logtype:\"${LOG_TYPE:-osm-poc-app}\" AND traceId:\"${TRACE}\""
echo ""
echo "  logtype:\"osm-poc-app\" AND traceId:\"${TRACE}\" AND service:ms-a"
echo "  logtype:\"osm-poc-app\" AND traceId:\"${TRACE}\" AND service:ms-b"
echo "  logtype:\"osm-poc-app\" AND traceId:\"${TRACE}\" AND (service:ms-c OR source:vsi)"
echo ""
echo "Expected 6+ lines with actions: CALL_B, FROM_A, CALL_C, FROM_B, CALL_A, FROM_C"
echo "Allow 30–90s for agent flush to IBM Cloud Logs."
