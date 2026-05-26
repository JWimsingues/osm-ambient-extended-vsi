# Demo Runbook — Microservice Calls and IBM Cloud Logs

This runbook explains **where to call each microservice**, **what you should see in IBM Cloud Logs**, and how to correlate a full **A → B → C → A** trace.

## Prerequisites

- PoC deployed (steps 1–5)
- IBM Cloud Logs configured ([`06-ibm-cloud-logs/`](../06-ibm-cloud-logs/))
- `LOG_FORMAT=json` on all three services
- Allow **30–90 seconds** after a test for agents to flush logs to IBM Cloud Logs

---

## 1. Where to call each microservice

### Recommended — full chain (in-mesh)

Use an **ambient** client inside `osm-poc-demo` so L4 `AuthorizationPolicy` identities apply.

```bash
export TRACE="demo-$(date +%Y%m%d-%H%M%S)"
oc -n osm-poc-demo run curl-demo --rm -i --restart=Never \
  --image=curlimages/curl \
  --labels="istio.io/dataplane-mode=ambient" \
  --command -- \
  curl -sv -H "X-Trace-Id: ${TRACE}" \
  http://ms-a.osm-poc-demo.svc.cluster.local:8080/api/run-chain
```

Or use the helper script:

```bash
cd 06-ibm-cloud-logs/scripts
TRACE_ID=my-client-demo ./run-demo-trace.sh
```

| Item | Value |
|---|---|
| **Caller** | Ephemeral pod in `osm-poc-demo` (ambient) |
| **Target** | `ms-a:8080` / `api/run-chain` |
| **Why** | Exercises A→B→C→A with mesh mTLS and policies |

### Optional — OpenShift Route (external / browser)

```bash
HOST=$(oc -n osm-poc-demo get route ms-a -o jsonpath='{.spec.host}')
curl -sk -H "X-Trace-Id: ${TRACE}" "https://${HOST}/api/call-b"
```

| Item | Value |
|---|---|
| **Caller** | Your laptop / bastion |
| **Target** | Route `ms-a` → partial path **A→B only** |
| **Note** | Ingress identity is **not** `sa/ms-a`; policy tests should use in-mesh calls |

### Optional — individual Routes

```bash
HOST_B=$(oc -n osm-poc-demo get route ms-b -o jsonpath='{.spec.host}')
curl -sk "https://${HOST_B}/api/info"
```

Direct calls to `ms-b` from the internet are typically **denied** by policy unless the caller has mesh identity `sa/ms-a`.

### VSI — ms-c only

On the VSI (SSH):

```bash
export TRACE="vsi-manual-test"
curl -s -H "X-Trace-Id: ${TRACE}" http://127.0.0.1:8080/api/call-a
```

| Item | Value |
|---|---|
| **Caller** | `localhost` on VSI |
| **Target** | `ms-c` → calls **ms-a** (C→A leg) |
| **Logs** | `/var/log/osm-poc/ms-c.log` → IBM Cloud Logs (`source:vsi`) |

---

## 2. IBM Cloud Logs — navigation

1. IBM Cloud console → **Observability** → your **IBM Cloud Logs** instance.
2. Open **Logs** (or **Log Explorer**).
3. Set time range to **Last 15 minutes**.
4. Paste queries from section 3.

Cluster logs usually include Kubernetes metadata, for example:

- `kubernetes.namespace_name:osm-poc-demo`
- `kubernetes.container_name:ms-a` (or `ms-b`)
- `kubernetes.cluster_name` (if set in Helm values)

VSI logs include custom fields from Fluent Bit:

- `source:vsi`
- `host:vsi-ms-c`

---

## 3. Queries to run

Replace `YOUR_TRACE_ID` with the value you sent in `X-Trace-Id`.

### Full trace (all services)

```text
logtype:"osm-poc-app" AND traceId:"YOUR_TRACE_ID"
```

### Per service

```text
logtype:"osm-poc-app" AND traceId:"YOUR_TRACE_ID" AND service:"ms-a"
logtype:"osm-poc-app" AND traceId:"YOUR_TRACE_ID" AND service:"ms-b"
logtype:"osm-poc-app" AND traceId:"YOUR_TRACE_ID" AND service:"ms-c"
```

### OpenShift namespace only

```text
kubernetes.namespace_name:"osm-poc-demo" AND traceId:"YOUR_TRACE_ID"
```

### VSI only

```text
source:"vsi" AND traceId:"YOUR_TRACE_ID"
```

If JSON parsing is enabled in your views, you can also use:

```text
action:"CALL_B" AND traceId:"YOUR_TRACE_ID"
```

---

## 4. Expected log sequence (IBM Cloud Logs)

After a successful **`/api/run-chain`** with trace id `YOUR_TRACE_ID`, you should see **at least six** application log lines in order:

| # | `service` | `action` | `message` (contains) | Origin |
|---|---|---|---|---|
| 1 | `ms-a` | `CALL_B` | `ms-a is calling ms-b` | ROCKS pod |
| 2 | `ms-b` | `FROM_A` | `ms-b received call from ms-a` | ROCKS pod |
| 3 | `ms-b` | `CALL_C` | `ms-b is calling ms-c` | ROCKS pod |
| 4 | `ms-c` | `FROM_B` | `ms-c received call from ms-b` | VSI |
| 5 | `ms-c` | `CALL_A` | `ms-c is calling ms-a` | VSI |
| 6 | `ms-a` | `FROM_C` | `ms-a received call from ms-c` | ROCKS pod |

### Example JSON line (as ingested)

```json
{
  "timestamp": "2026-05-26T14:32:01.123Z",
  "level": "INFO",
  "logtype": "osm-poc-app",
  "service": "ms-b",
  "traceId": "demo-20260526-143200",
  "action": "FROM_A",
  "message": "ms-b received call from ms-a"
}
```

In the IBM Cloud Logs UI, fields may appear at the root or under a `message` / `parsed` object depending on agent parsing — use **logtype** and **traceId** first, then filter by **service** and **action**.

---

## 5. Expected HTTP response (caller terminal)

Successful in-mesh `run-chain` returns JSON similar to:

```json
{
  "service": "ms-a",
  "traceId": "demo-20260526-143200",
  "result": "{\"service\":\"ms-b\",\"traceId\":\"demo-20260526-143200\",\"downstream\":\"{...ms-c...}\"}"
}
```

Nested JSON in `result` is normal (each hop wraps the previous response).

---

## 6. Troubleshooting

| Symptom | Check |
|---|---|
| No logs in IBM Cloud Logs | Agent DaemonSet `Running` on ROCKS; `systemctl status fluent-bit` on VSI; Sender IAM role |
| Only ms-a/ms-b, no ms-c | VSI Fluent Bit tailing `/var/log/osm-poc/ms-c.log`; Podman log path in `run-ms-c.sh` |
| Missing `traceId` field | `LOG_FORMAT=json` on deployments; rebuild images after code update |
| Chain fails with 502 | VSI ztunnel / `WorkloadEntry` IP; `ms-c` pod on VSI healthy |
| Route works but no policy demo | Use in-mesh curl, not Route, for full chain + policies |

---

## 7. Demo script timeline (client presentation)

| Step | Action | Show in IBM Cloud Logs |
|---|---|---|
| 1 | Open Logs viewer, set Last 15 min | Empty or baseline |
| 2 | Run `run-demo-trace.sh` | Note printed `traceId` |
| 3 | Wait ~60 s | — |
| 4 | Query `logtype:"osm-poc-app" AND traceId:"..."` | 6 lines, 3 services |
| 5 | Expand `ms-c` rows | `source:vsi` |
| 6 | Optional: Route `curl /api/call-b` | Only ms-a + ms-b actions |

---

## Official documentation

- [IBM Cloud Logs — Getting started](https://cloud.ibm.com/docs/cloud-logs?topic=cloud-logs-getting-started)
- [Logging agent on OpenShift](https://cloud.ibm.com/docs/cloud-logs?topic=cloud-logs-agent-helm-os-deploy)
- [Logging agent overview](https://cloud.ibm.com/docs/cloud-logs?topic=cloud-logs-agent-about)
- [OpenShift on IBM Cloud logging](https://cloud.ibm.com/docs/openshift?topic=openshift-logging)
