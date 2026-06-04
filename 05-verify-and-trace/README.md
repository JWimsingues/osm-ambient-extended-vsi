# Step 5 — Verify Traffic and Follow Trace Logs

Validates the **A → B → C → A** chain, confirms RBAC enforcement, and shows how to
correlate the `X-Trace-Id` across all three services.

---

## Pre-flight checks

Run these before the chain test to confirm the mesh and VSI sidecar are healthy.

```bash
# 1. All proxies synced with istiod
istioctl proxy-status
```

Expected output includes all four proxies (no STALE):
```
NAME                                    CLUSTER         VERSION
istio-eastwestgateway-xxx.istio-system  rocks-cluster   1.28.6
ms-a-xxx.osm-poc-demo                   rocks-cluster   1.28.6
ms-b-xxx.osm-poc-demo                   rocks-cluster   1.28.6
vsi-jwims.osm-poc-demo                  rocks-cluster   1.28.6
```

```bash
# 2. VSI WorkloadEntry auto-registered
oc get workloadentry -n osm-poc-demo
# → ms-c-161.156.86.195-vm-network   <age>   161.156.86.195

# 3. Authorization policies in place
oc get authorizationpolicy -n osm-poc-demo
# → ms-a-allow-ingress, ms-b-allow-from-a, ms-c-allow-from-b

# 4. Pods running (2/2 = app + istio-proxy sidecar)
oc get pod -n osm-poc-demo
# → ms-a-xxx  2/2  Running
# → ms-b-xxx  2/2  Running

# 5. VSI sidecar active
ssh vpcuser@161.156.86.195 'sudo systemctl is-active istio'
# → active
```

---

## Step 5.1 — Run the full chain with a trace ID

```bash
# Get the ms-a Route hostname
MS_A_URL="https://$(oc get route ms-a -n osm-poc-demo -o jsonpath='{.spec.host}')"

# Generate a trace ID and call the chain
TRACE=$(uuidgen | tr '[:upper:]' '[:lower:]')
echo "Trace ID: ${TRACE}"

curl -sk -H "X-Trace-Id: ${TRACE}" "${MS_A_URL}/api/run-chain" | python3 -m json.tool
```

**Expected response (HTTP 200, ~100–500 ms):**
```json
{
  "service": "ms-a",
  "traceId": "<your-trace-id>",
  "result": "{\"service\":\"ms-b\",\"traceId\":\"...\",\"downstream\":\"{\\\"service\\\":\\\"ms-c\\\",...\\\"downstream\\\":\\\"{\\\\\\\"service\\\\\\\":\\\\\\\"ms-a\\\\\\\",\\\\\\\"message\\\\\\\":\\\\\\\"ms-a handled request from ms-c\\\\\\\"}\\\"}\"}\"}"
}
```

---

## Step 5.2 — Follow trace logs across all services

Open three terminals and grep for the trace ID.

**Terminal 1 — ms-a (cluster):**
```bash
oc logs -n osm-poc-demo deployment/ms-a -c ms-a --since=5m | grep "${TRACE}"
```

**Terminal 2 — ms-b (cluster):**
```bash
oc logs -n osm-poc-demo deployment/ms-b -c ms-b --since=5m | grep "${TRACE}"
```

**Terminal 3 — ms-c (VSI):**
```bash
ssh vpcuser@161.156.86.195 "grep '${TRACE}' /tmp/ms-c-app.log"
```

**Expected log sequence (same `traceId` across all three):**

| Order | Service | Action   | Message |
|-------|---------|----------|---------|
| 1     | ms-a    | CALL_B   | ms-a is calling ms-b |
| 2     | ms-b    | FROM_A   | ms-b received call from ms-a |
| 3     | ms-b    | CALL_C   | ms-b is calling ms-c |
| 4     | ms-c    | FROM_B   | ms-c received call from ms-b |
| 5     | ms-c    | CALL_A   | ms-c is calling ms-a (closing the loop) |
| 6     | ms-a    | FROM_C   | ms-a received call from ms-c (end of chain) |

---

## Step 5.3 — Verify RBAC enforcement

The `AuthorizationPolicy` resources restrict each service to call only its designated downstream.
All checks use `curl` from within the running pod via `oc exec`.

```bash
# A → B: ALLOWED (ms-a can call ms-b)
oc exec -n osm-poc-demo deployment/ms-a -c ms-a -- \
  curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  http://ms-b.osm-poc-demo.svc.cluster.local:8080/health
# Expected: 200
```

```bash
# A → C: BLOCKED (ms-a cannot call ms-c directly)
oc exec -n osm-poc-demo deployment/ms-a -c ms-a -- \
  curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  http://ms-c.osm-poc-demo.svc.cluster.local:8080/health
# Expected: 403
```

```bash
# B → C: ALLOWED (ms-b can call ms-c)
oc exec -n osm-poc-demo deployment/ms-b -c ms-b -- \
  curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  http://ms-c.osm-poc-demo.svc.cluster.local:8080/health
# Expected: 200
```

```bash
# B → A: BLOCKED (ms-b cannot call ms-a)
oc exec -n osm-poc-demo deployment/ms-b -c ms-b -- \
  curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  http://ms-a.osm-poc-demo.svc.cluster.local:8080/health
# Expected: 403
```

```bash
# External → A: ALLOWED (OpenShift Route, no Istio identity)
curl -sk -o /dev/null -w "%{http_code}" "${MS_A_URL}/health"
# Expected: 200
```

---

## Step 5.4 — Inspect mesh endpoints

```bash
# EW gateway endpoints pushed to the VM proxy (should show external IPs :15443, not pod IPs)
istioctl proxy-config endpoints vsi-jwims.osm-poc-demo 2>/dev/null | grep "ms-a"
# Expected: 158.177.15.125:15443 and/or 161.156.163.1:15443

# Check what endpoint the VM proxy has for ms-b
istioctl proxy-config endpoints vsi-jwims.osm-poc-demo 2>/dev/null | grep "ms-b"

# AuthZ policy decision for a given request (requires istioctl 1.18+)
istioctl x authz check deployment/ms-a.osm-poc-demo 2>/dev/null | head -20
```

---

## Step 5.5 — Service info endpoints

Each microservice exposes `/api/info` describing its role and allowed callers:

```bash
# ms-a info (via Route)
curl -sk "${MS_A_URL}/api/info" | python3 -m json.tool

# ms-b info (from inside ms-a pod — cross-sidecar)
oc exec -n osm-poc-demo deployment/ms-a -c ms-a -- \
  curl -s http://ms-b.osm-poc-demo.svc.cluster.local:8080/api/info | python3 -m json.tool

# ms-c info (from inside ms-b pod — cross-network)
oc exec -n osm-poc-demo deployment/ms-b -c ms-b -- \
  curl -s http://ms-c.osm-poc-demo.svc.cluster.local:8080/api/info | python3 -m json.tool
```

---

## Step 5.6 — IBM Cloud Logs (optional)

To export and query the same trace in IBM Cloud Logs, see
[`docs/demo-runbook-ibm-cloud-logs.md`](../docs/demo-runbook-ibm-cloud-logs.md)
and run [`06-ibm-cloud-logs/scripts/run-demo-trace.sh`](../06-ibm-cloud-logs/scripts/run-demo-trace.sh).

---

## Quick summary table

| Check | Command | Expected |
|-------|---------|----------|
| Chain (HTTP) | `curl "${MS_A_URL}/api/run-chain"` | `200` |
| ms-a → ms-b | `oc exec ms-a -- curl ms-b:8080/health` | `200` |
| ms-a → ms-c | `oc exec ms-a -- curl ms-c:8080/health` | `403` |
| ms-b → ms-c | `oc exec ms-b -- curl ms-c:8080/health` | `200` |
| ms-b → ms-a | `oc exec ms-b -- curl ms-a:8080/health` | `403` |
| VSI sidecar  | `systemctl is-active istio` on VSI | `active` |
| WorkloadEntry | `oc get workloadentry -n osm-poc-demo` | `ms-c-161.156.86.195-vm-network` |
