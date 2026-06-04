#!/usr/bin/env bash
# Verify ambient control plane and multi-network settings after step 2 apply.
set -euo pipefail

fail=0
ok() { echo "OK: $*"; }
err() { echo "ERROR: $*" >&2; fail=1; }

oc wait --for=condition=Ready istio/default -n istio-system --timeout=10m &>/dev/null \
  && ok "istio/default Ready" \
  || err "istio/default not Ready"

meshnets="$(oc get istio default -n istio-system -o jsonpath='{.spec.values.global.meshNetworks}' 2>/dev/null || true)"
if [[ -n "${meshnets}" && "${meshnets}" != "{}" && "${meshnets}" != "null" ]]; then
  ok "meshNetworks present on Istio CR"
else
  err "meshNetworks missing — run: oc apply -f 01-istio-ambient.yaml"
fi
if echo "${meshnets}" | grep -q 'main-network'; then
  ok "meshNetworks defines main-network (east-west HBONE for VSI outbound)"
else
  err "meshNetworks must key main-network (not vsi-network) — re-apply 01-istio-ambient.yaml"
fi

multi="$(oc -n istio-system get deploy istiod -o json \
  | python3 -c "import sys,json; env={e['name']:e.get('value','') for e in json.load(sys.stdin)['spec']['template']['spec']['containers'][0]['env']}; print(env.get('AMBIENT_ENABLE_MULTI_NETWORK',''))" 2>/dev/null || true)"
if [[ "${multi}" == "true" ]]; then
  ok "istiod AMBIENT_ENABLE_MULTI_NETWORK=true"
else
  err "istiod AMBIENT_ENABLE_MULTI_NETWORK is not true (got '${multi}')"
fi

oc -n istio-system rollout status deploy/istiod --timeout=5m &>/dev/null \
  && ok "istiod rolled out" \
  || err "istiod rollout incomplete"

if oc -n ztunnel get pods --field-selector=status.phase=Running 2>/dev/null | grep -qE '^ztunnel-'; then
  ok "ztunnel pods Running"
else
  err "no Running ztunnel pods in namespace ztunnel"
fi

exit "${fail}"
