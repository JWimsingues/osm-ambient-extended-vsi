# Step 6 — Export Logs to IBM Cloud Logs (ROCKS + VSI)

## Summary

Configures **IBM Cloud Logs** ingestion from:

- **ROCKS (OpenShift)**: IBM Cloud Logs agent (Helm) or ROKS cluster logging integration — collects container **stdout** from `ms-a` and `ms-b` in `osm-poc-demo`.
- **VSI**: Fluent Bit agent tailing `/var/log/osm-poc/ms-c.log` (written by the `ms-c` systemd service).

Application logs use **JSON** (`LOG_FORMAT=json`) with fields `traceId`, `service`, `action`, and `logtype=osm-poc-app` for correlation in IBM Cloud Logs.

## Prerequisites

- IBM Cloud Logs instance provisioned in the **same account** as ROCKS (or Service ID API key for cross-account)
- IAM **Sender** role on the logs instance ([Granting IAM permissions for ingestion](https://cloud.ibm.com/docs/cloud-logs?topic=cloud-logs-iam-ingestion))
- Ingestion host and port from the instance UI (e.g. `<guid>.ingress.eu-de.logs.cloud.ibm.com:443`)
- Steps 1–5 of this PoC completed

## Steps — OpenShift (ROCKS)

### Option A — ROKS integrated logging (fastest for demos)

If your cluster is already connected to IBM Cloud Logs via the console:

1. OpenShift console → your cluster → **Observability** / **Logging** → confirm IBM Cloud Logs instance is linked.
2. Ensure `osm-poc-demo` workloads log to stdout (default).
3. Skip to [Verify ingestion](#verify-ingestion).

See [Managing logging for ROKS](https://cloud.ibm.com/docs/openshift?topic=openshift-logging).

### Option B — IBM Cloud Logs agent (Helm)

1. Copy and edit the values template:

   ```bash
   cd 06-ibm-cloud-logs
   cp logs-agent-values.yaml.template logs-agent-values.yaml
   # Set ingestionHost, ingestionPort, trustedProfileID or use IAM API key
   ```

2. Install the agent:

   ```bash
   export IAM_API_KEY=<sender-api-key>   # if iamMode=IAMAPIKey
   ./01-install-openshift-logs-agent.sh
   ```

3. Enable JSON logs on microservices (if not already):

   ```bash
   oc -n osm-poc-demo set env deploy/ms-a deploy/ms-b LOG_FORMAT=json
   oc -n osm-poc-demo rollout status deploy/ms-a deploy/ms-b
   ```

Official reference: [Deploy Logging agent on OpenShift (Helm)](https://cloud.ibm.com/docs/cloud-logs?topic=cloud-logs-agent-helm-os-deploy).

## Steps — VSI

`ms-c` runs as a systemd service and writes structured JSON logs to `/var/log/osm-poc/ms-c.log`.
The Fluent Bit agent tails this file and ships logs to IBM Cloud Logs.

1. Copy VSI config template and set ingestion credentials:

   ```bash
   cp vsi/fluent-bit-ms-c.conf.template vsi/fluent-bit-ms-c.conf
   # Edit: INGESTION_HOST, INGESTION_PORT, IAM_API_KEY, CLUSTER_NAME
   ```

2. Copy agent scripts to VSI and run installer:

   ```bash
   VSI_PUBLIC_IP=<VSI_PUBLIC_IP>
   scp -r vsi vpcuser@${VSI_PUBLIC_IP}:/tmp/osm-poc-logs/
   ssh vpcuser@${VSI_PUBLIC_IP} \
     "INGESTION_HOST=<host> INGESTION_PORT=443 IAM_API_KEY=<key> \
      sudo -E bash /tmp/osm-poc-logs/install-logs-agent-vsi.sh"
   ```

   The installer deploys Fluent Bit, writes `/etc/fluent-bit/osm-poc-ms-c.conf` (from your edited template),
   and enables the `fluent-bit` systemd service.

See [About the Logging agent](https://cloud.ibm.com/docs/cloud-logs?topic=cloud-logs-agent-about) and [Fluent Bit agent configuration](https://cloud.ibm.com/docs/cloud-logs?topic=cloud-logs-agent-fluentbit).

## Verify ingestion

```bash
# Generate a known trace id and run the chain
./scripts/run-demo-trace.sh
```

In **IBM Cloud Logs** → **Logs** viewer, run the queries in [`docs/demo-runbook-ibm-cloud-logs.md`](../docs/demo-runbook-ibm-cloud-logs.md).

## Demo procedure (where to call / expected output)

Full client demo script: **[`docs/demo-runbook-ibm-cloud-logs.md`](../docs/demo-runbook-ibm-cloud-logs.md)**

| Call from | URL / command | Purpose |
|---|---|---|
| In-mesh client (recommended) | `http://ms-a:8080/api/run-chain` | Full A→B→C→A + policies |
| OpenShift Route | `https://<ms-a-route>/api/call-b` | Partial path / external ingress |
| VSI localhost | `http://127.0.0.1:8080/api/call-a` | C→A leg only |

## Official Documentation

- [IBM Cloud Logs — Getting started](https://cloud.ibm.com/docs/cloud-logs?topic=cloud-logs-getting-started)
- [Logging agent on OpenShift (Helm)](https://cloud.ibm.com/docs/cloud-logs?topic=cloud-logs-agent-helm-os-deploy)
- [Logging agent overview](https://cloud.ibm.com/docs/cloud-logs?topic=cloud-logs-agent-about)
- [OpenShift on IBM Cloud — logging](https://cloud.ibm.com/docs/openshift?topic=openshift-logging)
