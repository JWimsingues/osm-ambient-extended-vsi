# Step 5 — Verify Traffic and Follow Trace Logs

> Troubleshooting snapshot (2026-06-03): [`docs/troubleshooting-session-2026-06-03.md`](../docs/troubleshooting-session-2026-06-03.md).  
> Future install fixes (agent prompt): [`docs/FUTURE-FIX-PROMPT.md`](../docs/FUTURE-FIX-PROMPT.md).

## Description

Validates the **A → B → C → A** chain and shows how to correlate logs using `X-Trace-Id` across cluster pods and the VSI.

## Pre-flight (automated checks)

```bash
# After step 2
cd ../02-ambient-mesh && ./verify-ambient.sh

# On the VSI (after step 4)
sudo verify-ztunnel.sh
```

## Acceptance checklist

| # | Check | Command |
|---|--------|---------|
| 1 | meshNetworks on Istio CR | `02-ambient-mesh/verify-ambient.sh` |
| 2 | ms-c ztunnel endpoints | `istioctl ztunnel-config service -n ztunnel \| grep ms-c` → **1/1** |
| 3 | B→C health | `oc exec deploy/ms-b -- curl -sf http://ms-c:8080/health` |
| 4 | B→C handler (C→A egress) | `oc exec deploy/ms-b -- curl -sf http://ms-c:8080/api/handle-from-b` |
| 5 | VSI iptables redirect | `sudo iptables -t nat -S OSM_ZTUNNEL_OUT \| grep 15001` |
| 6 | Full ring | mesh-curl `run-chain` below |

## Prerequisites

- All prior steps completed
- `ms-c` and `ztunnel` running on the VSI

## Steps

1. Generate a trace id and invoke the chain from an **in-mesh** client (recommended — respects L4 policies):

   ```bash
   TRACE=$(uuidgen | tr '[:upper:]' '[:lower:]')
   oc -n osm-poc-demo run mesh-curl --rm -i --restart=Never \
     --image=curlimages/curl \
     --overrides='{"metadata":{"labels":{"istio.io/dataplane-mode":"ambient","ambient.istio.io/redirection":"enabled"}}}' \
     --command -- curl -sv \
       -H "X-Trace-Id: ${TRACE}" \
       http://ms-a:8080/api/run-chain
   ```

2. Tail logs in parallel:

   ```bash
   oc -n osm-poc-demo logs deploy/ms-a --since=2m | grep "${TRACE}"
   oc -n osm-poc-demo logs deploy/ms-b --since=2m | grep "${TRACE}"
   ssh root@VSI 'podman logs ms-c 2>&1 | grep '"${TRACE}"''
   ```

3. Negative test — ms-a must not reach ms-c directly:

   ```bash
   oc -n osm-poc-demo exec deploy/ms-a -- \
     curl -s -o /dev/null -w "%{http_code}" http://ms-c:8080/health || true
   ```

   Expect connection reset / RBAC denial (not HTTP 200 from mesh policy).

4. OpenShift/Kiali (optional):

   ```bash
   oc get kiali -A
   ```

   Inspect ambient workloads and ztunnel metrics in the Kiali console.

## Expected Log Sequence

| Order | Service | Action |
|---|---|---|
| 1 | ms-a | `CALL_B` |
| 2 | ms-b | `FROM_A` |
| 3 | ms-b | `CALL_C` |
| 4 | ms-c | `FROM_B` |
| 5 | ms-c | `CALL_A` |
| 6 | ms-a | `FROM_C` |

## IBM Cloud Logs

To export and query the same trace in IBM Cloud Logs, see [`docs/demo-runbook-ibm-cloud-logs.md`](../docs/demo-runbook-ibm-cloud-logs.md) and run [`06-ibm-cloud-logs/scripts/run-demo-trace.sh`](../06-ibm-cloud-logs/scripts/run-demo-trace.sh).

## Official Documentation

- [ztunnel telemetry](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/installing/ossm-istio-ambient-mode)
- [Kiali for OSM](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/installing/ossm-installing-kiali)
- [IBM Cloud Logs](https://cloud.ibm.com/docs/cloud-logs?topic=cloud-logs-getting-started)
