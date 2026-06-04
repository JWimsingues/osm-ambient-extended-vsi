#!/usr/bin/env bash
# Run the PoC chain with a fixed trace id and print IBM Cloud Logs query hints.
set -euo pipefail

TRACE="${TRACE_ID:-demo-$(date +%Y%m%d-%H%M%S)}"
NS="${NAMESPACE:-osm-poc-demo}"

MS_A_HOST=$(oc -n "${NS}" get route ms-a -o jsonpath='{.spec.host}' 2>/dev/null)
: "${MS_A_HOST:?Could not resolve ms-a Route — run: oc get route ms-a -n ${NS}}"
MS_A_URL="https://${MS_A_HOST}"

echo "==> Trace id:  ${TRACE}"
echo "==> Calling:   ${MS_A_URL}/api/run-chain"

curl -sk -H "X-Trace-Id: ${TRACE}" "${MS_A_URL}/api/run-chain" | tee /tmp/osm-poc-response.json
echo ""

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
