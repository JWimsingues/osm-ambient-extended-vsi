#!/usr/bin/env bash
# Verify ambient control plane and multi-network settings after step 2.
set -euo pipefail

fail=0
ok()  { echo "OK:    $*"; }
err() { echo "ERROR: $*" >&2; fail=1; }

# --- Istio CR ---
oc wait --for=condition=Ready istio/default -n istio-system --timeout=10m &>/dev/null \
  && ok "istio/default Ready" \
  || err "istio/default not Ready"

# --- meshNetworks (required for VM sidecar routing) ---
meshnets="$(oc get istio default -n istio-system \
  -o jsonpath='{.spec.values.global.meshNetworks}' 2>/dev/null || true)"
if [[ -n "${meshnets}" && "${meshnets}" != "{}" && "${meshnets}" != "null" ]]; then
  ok "meshNetworks present on Istio CR"
else
  err "meshNetworks missing — re-apply 01-istio-ambient.yaml"
fi
if echo "${meshnets}" | grep -q 'main-network'; then
  ok "meshNetworks defines main-network (VM sidecar routes C→A via EW gateway port 15443)"
else
  err "meshNetworks must define main-network — re-apply 01-istio-ambient.yaml"
fi

# --- AMBIENT_ENABLE_MULTI_NETWORK ---
multi="$(oc -n istio-system get deploy istiod -o json \
  | python3 -c "import sys,json; env={e['name']:e.get('value','') for e in json.load(sys.stdin)['spec']['template']['spec']['containers'][0]['env']}; print(env.get('AMBIENT_ENABLE_MULTI_NETWORK',''))" \
  2>/dev/null || true)"
if [[ "${multi}" == "true" ]]; then
  ok "istiod AMBIENT_ENABLE_MULTI_NETWORK=true"
else
  err "istiod AMBIENT_ENABLE_MULTI_NETWORK is not true (got '${multi}') — re-apply 01-istio-ambient.yaml"
fi

# --- istiod rollout ---
oc -n istio-system rollout status deploy/istiod --timeout=5m &>/dev/null \
  && ok "istiod rolled out" \
  || err "istiod rollout incomplete"

# --- ztunnel pods (cluster DaemonSet) ---
if oc -n ztunnel get pods 2>/dev/null | awk 'NR>1 && $3=="Running" {found=1} END{exit !found}'; then
  ok "ztunnel pods Running (cluster DaemonSet)"
else
  err "no Running ztunnel pods in namespace ztunnel"
fi

# --- East-west gateway Deployment ---
if oc -n istio-system get deploy istio-eastwestgateway &>/dev/null; then
  ok "east-west gateway Deployment present (istio-system)"
else
  err "east-west gateway Deployment missing — run ./apply-eastwest-gateway.sh"
fi

# --- East-west gateway LoadBalancer Service ---
ew_lb="$(oc -n istio-system get svc istio-eastwestgateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
if [[ -n "${ew_lb}" ]]; then
  ok "east-west gateway LoadBalancer hostname: ${ew_lb}"
else
  err "east-west gateway Service has no LoadBalancer hostname yet — wait or check IBM Cloud"
fi

exit "${fail}"
