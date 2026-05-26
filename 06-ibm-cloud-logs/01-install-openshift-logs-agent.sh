#!/usr/bin/env bash
# Install IBM Cloud Logs agent on OpenShift via Helm (ROCKS).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/logs-agent-values.yaml"
NAMESPACE="${LOGS_AGENT_NAMESPACE:-ibm-observe}"
RELEASE="${LOGS_AGENT_RELEASE:-logs-agent}"
CHART_VERSION="${LOGS_AGENT_CHART_VERSION:-1.6.0}"

if [[ ! -f "${VALUES_FILE}" ]]; then
  echo "Missing ${VALUES_FILE}. Copy logs-agent-values.yaml.template and edit it." >&2
  exit 1
fi

helm version >/dev/null 2>&1 || { echo "helm is required" >&2; exit 1; }

HELM_EXTRA=()
if [[ -n "${IAM_API_KEY:-}" ]]; then
  HELM_EXTRA+=(--set "secret.iamAPIKey=${IAM_API_KEY}" --hide-secret)
fi

echo "==> Installing IBM Cloud Logs agent in namespace ${NAMESPACE}"
helm upgrade --install "${RELEASE}" \
  oci://icr.io/ibm/observe/logs-agent-helm \
  --version "${CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --values "${VALUES_FILE}" \
  "${HELM_EXTRA[@]}"

echo "==> Waiting for DaemonSet pods"
oc -n "${NAMESPACE}" rollout status daemonset/"${RELEASE}" --timeout=300s 2>/dev/null \
  || oc -n "${NAMESPACE}" get pods

echo "Done. Enable JSON app logs: oc -n osm-poc-demo set env deploy/ms-a deploy/ms-b LOG_FORMAT=json"
