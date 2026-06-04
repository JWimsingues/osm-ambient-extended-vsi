# PoC: OpenShift Service Mesh 3.3 — VM Integration with ROCKS + IBM Cloud VSI

> **Based on:** [Integrate Red Hat Enterprise Linux VMs into OpenShift Service Mesh](https://developers.redhat.com/articles/2026/04/17/integrate-red-hat-enterprise-linux-vms-openshift-service-mesh) — Red Hat Developer, April 2026 (Yann Liu)

## Summary

Demonstrates **OpenShift Service Mesh (OSM) 3.3** (Istio **1.28.6**) on a **ROCKS** cluster (OpenShift on IBM Cloud) with two Java microservices in-cluster (**ms-a**, **ms-b**) and a third (**ms-c**) on an **IBM Cloud VSI**, joined to the mesh via `istio-sidecar.rpm` and a multi-network east-west gateway. Traffic follows a strict ring **A → B → C → A** enforced by `AuthorizationPolicy` and correlated by `X-Trace-Id` logs.

## Why integrate a VM into the mesh?

From the Red Hat article — the three benefits of running an Envoy proxy alongside a non-containerised workload:

| Benefit | What it means in this PoC |
|---|---|
| **Zero-trust security** | mTLS between cluster pods and the VSI — no IP allowlists needed; identity is SPIFFE-based |
| **Observability** | Golden-signal metrics (latency, traffic, errors) for ms-c on the VSI, forwarded to IBM Cloud Logs |
| **Traffic management** | AuthorizationPolicy, circuit breaking, and retries apply to VSI workloads just like cluster pods |

## Environment

| Item         | Value |
| ------------ | ----- |
| OpenShift    | 4.20+ (ROCKS on IBM Cloud) |
| Service Mesh | OSM **3.3** (Sail Operator, ambient profile, Istio 1.28.6) |
| CNI          | OVN-Kubernetes (`routingViaHost: true`) |
| Edge         | IBM Cloud **VSI** (RHEL 9.6+) |
| Images       | `registry.access.redhat.com/ubi9/openjdk-21-runtime` → Quay.io |

## Architecture diagrams

- [Deployment placement (ROCKS vs VSI)](docs/architecture-deployment.md)
- [Communication matrix and policies](docs/communication-policy.md)

## Repository structure

| Folder | Purpose |
| ------ | ------- |
| [`microservices/`](microservices/) | Java source, Containerfiles, Quay build script |
| [`01-setup/`](01-setup/) | Sail Operator subscription, mesh namespaces |
| [`02-ambient-mesh/`](02-ambient-mesh/) | Istio / IstioCNI / ZTunnel CRs, east-west gateway |
| [`03-deploy-microservices/`](03-deploy-microservices/) | ms-a & ms-b Deployments, Routes, policies, WorkloadGroup for ms-c |
| [`04-vsi-sidecar/`](04-vsi-sidecar/) | VSI onboarding runbook (istio-sidecar.rpm approach) |
| [`05-verify-and-trace/`](05-verify-and-trace/) | End-to-end test and log correlation |
| [`06-ibm-cloud-logs/`](06-ibm-cloud-logs/) | Ship ROCKS + VSI logs to IBM Cloud Logs |
| [`docs/demo-runbook-ibm-cloud-logs.md`](docs/demo-runbook-ibm-cloud-logs.md) | Where to call each MS + expected Logs UI output |

## Quick start

1. Build and push images: [`microservices/build-and-push.sh`](microservices/build-and-push.sh)
2. Install operator: [`01-setup/`](01-setup/)
3. Install ambient mesh: [`02-ambient-mesh/`](02-ambient-mesh/)
4. Deploy cluster services: [`03-deploy-microservices/`](03-deploy-microservices/)
5. Onboard VSI with istio-sidecar.rpm: [`04-vsi-sidecar/`](04-vsi-sidecar/)
6. Verify traces: [`05-verify-and-trace/`](05-verify-and-trace/)
7. IBM Cloud Logs: [`06-ibm-cloud-logs/`](06-ibm-cloud-logs/)

## Network topology

This PoC uses a **multi-network** mesh — the cluster and the VSI are on separate networks with no direct pod-to-VM IP routing:

| Network | Workloads | Gateway |
|---|---|---|
| `main-network` | ms-a, ms-b (cluster pods) | East-west gateway LB `:15443` (used by VM → cluster) |
| `vm-network` | ms-c (IBM Cloud VSI) | None — cluster pods connect **directly** to the VM's public IP |

The east-west gateway bridges the two networks:
- **Control plane:** The VM sidecar connects to `istiod` through the EW gateway's public IP on port 15012.
- **Data plane (C → A):** VM Envoy routes to `main-network` services via EW gateway port 15443 (`AUTO_PASSTHROUGH` SNI routing).
- **Data plane (B → C):** `ms-b`'s Envoy connects **directly** to the VM's registered IP (no gateway hop needed since `vm-network` has no gateway defined in `meshNetworks`).

## Sidecar mode note

All three services use Envoy **sidecar** injection, not ambient ztunnel:

- **ms-a** and **ms-b** run on the cluster with `sidecar.istio.io/inject: "true"` and `ambient.istio.io/redirection: disabled`
- **ms-c** runs on the VSI with `istio-sidecar.rpm`

The cluster still runs the full ambient infrastructure (IstioCNI, ZTunnel DaemonSet) because `AMBIENT_ENABLE_MULTI_NETWORK` is required for cross-network endpoint discovery. However, the application pods explicitly opt out of ambient mode. This is required because the EW gateway (`HBONEPort: 0` in this OSM 3.3 release) does not relay HBONE connections from external VMs to ambient pods; sidecar mode causes Istiod to push EW gateway IPs (port 15443) as endpoints instead.

## Key implementation notes (from article)

### VM public IP
IBM Cloud VSIs use NAT; the sidecar auto-detects the **private** NIC IP, which is unreachable from the cluster. Override it explicitly in `cluster.env`:
```
INSTANCE_IP='<VSI_PUBLIC_IP>'
ISTIO_SVC_IP='<VSI_PUBLIC_IP>'
```

### Token TTL
The `istio-token` is a short-lived bound service account token (24 h). The Envoy proxy rotates its mTLS certificates automatically. The token only needs to be renewed if the VM is stopped for longer than 24 h:
```bash
oc create token ms-c -n osm-poc-demo --audience=istio-ca --duration=86400s \
  | ssh vpcuser@<VSI_IP> 'sudo tee /var/run/secrets/tokens/istio-token > /dev/null \
    && sudo systemctl restart istio'
```

### iptables interception
`pilot-agent` (part of `istio-sidecar.rpm`) automatically configures iptables rules (`ISTIO_INBOUND`, `ISTIO_OUTPUT`) when `systemctl start istio` runs. No manual iptables setup is needed — but be aware this intercepts **all** outbound traffic on the VM, including traffic from other applications.

### Firewall
Open the required ports on the VSI before starting the istio service:
```bash
sudo firewall-cmd --permanent --add-port=8080/tcp   # ms-c application
sudo firewall-cmd --permanent --add-port=15021/tcp  # sidecar health check
sudo firewall-cmd --permanent --add-port=15090/tcp  # Prometheus metrics
sudo firewall-cmd --reload
```

## Chain verification

```bash
MS_A_URL="https://$(oc get route ms-a -n osm-poc-demo -o jsonpath='{.spec.host}')"

# Health
curl -sk ${MS_A_URL}/health

# Full chain A → B → C → A (expect HTTP 200 in ~200–600 ms)
TRACE=$(uuidgen | tr '[:upper:]' '[:lower:]')
curl -sk -H "X-Trace-Id: ${TRACE}" ${MS_A_URL}/api/run-chain
```

Expected JSON response shows all services responding with the same `traceId`:
```json
{
  "service": "ms-a",
  "traceId": "<uuid>",
  "result": "...ms-b...ms-c...ms-a handled request from ms-c..."
}
```

## Requirements mapping (client checklist)

| # | Requirement | Location |
|---|---|---|
| 1 | 3 Java MS, Red Hat OpenJDK, Routes / localhost | `microservices/`, Routes in `03-deploy-microservices/04-services-routes.yaml` |
| 2 | A→B, B→C, C→A only | `docs/communication-policy.md`, `06-authorization-policies.yaml` |
| 3 | A,B on ROCKS; C on VSI | `docs/architecture-deployment.md` |
| 4 | Deployment diagram | `docs/architecture-deployment.md` |
| 5 | Authorization diagram | `docs/communication-policy.md` |
| 6 | OSM ambient + ms-a/ms-b procedure | `02-ambient-mesh/`, `03-deploy-microservices/` |
| 7 | VSI sidecar + mesh join | `04-vsi-sidecar/` |
| 8 | Traceable logs | JSON logs + `X-Trace-Id`; `05-verify-and-trace/`, `06-ibm-cloud-logs/` |
| 9 | Code + Containerfile + Quay script | `microservices/` |
| 10 | All Deployment manifests | `03-deploy-microservices/` |

## Official documentation

- [OSM 3.3 Installing](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/index)
- [Istio ambient mode (OSM 3.3)](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode)
- [**Integrate Red Hat Enterprise Linux VMs into OpenShift Service Mesh**](https://developers.redhat.com/articles/2026/04/17/integrate-red-hat-enterprise-linux-vms-openshift-service-mesh) ← primary reference for this PoC
- [OSM 3.3 Release notes](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/release_notes/ossm-release-notes)
