# PoC: OpenShift Service Mesh 3.3 — Ambient Mode with ROCKS + IBM Cloud VSI

## Summary

Demonstrates **OpenShift Service Mesh (OSM) 3.3** in **Istio ambient mode** (Istio **1.28.6**) on a **ROCKS** cluster (OpenShift on IBM Cloud) with two Java microservices in-cluster (**ms-a**, **ms-b**) and a third (**ms-c**) on an **IBM Cloud VSI**, joined via the **`istio-sidecar.rpm`** and a multi-network east-west gateway. Traffic follows a strict ring **A → B → C → A** enforced by `AuthorizationPolicy` and correlated by `X-Trace-Id` logs.

Reference: [Integrate Red Hat Enterprise Linux VMs with OpenShift Service Mesh](https://developers.redhat.com/articles/2026/04/17/integrate-red-hat-enterprise-linux-vms-openshift-service-mesh)

## Environment

| Item         | Value                                                          |
| ------------ | -------------------------------------------------------------- |
| OpenShift    | 4.20+ (ROCKS on IBM Cloud)                                     |
| Service Mesh | OSM **3.3** (Sail Operator, ambient profile, Istio 1.28.6)    |
| CNI          | OVN-Kubernetes (`routingViaHost: true`)                        |
| Edge         | IBM Cloud **VSI** (RHEL 9.6+)                                  |
| Images       | `registry.access.redhat.com/ubi9/openjdk-21-runtime` → Quay.io |

## Architecture diagrams

- [Deployment placement (ROCKS vs VSI)](docs/architecture-deployment.md)
- [Communication matrix and policies](docs/communication-policy.md)

## Repository structure

| Folder                                                                       | Purpose                                                           |
| ---------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| [`microservices/`](microservices/)                                           | Java source, Containerfiles, Quay build script                    |
| [`01-setup/`](01-setup/)                                                     | Sail Operator subscription, mesh namespaces                       |
| [`02-ambient-mesh/`](02-ambient-mesh/)                                       | Istio / IstioCNI / ZTunnel CRs, east-west gateway                 |
| [`03-deploy-microservices/`](03-deploy-microservices/)                       | ms-a & ms-b Deployments, Routes, policies, WorkloadGroup for ms-c |
| [`04-vsi-sidecar/`](04-vsi-sidecar/)                                         | VSI onboarding runbook (istio-sidecar.rpm approach)               |
| [`05-verify-and-trace/`](05-verify-and-trace/)                               | End-to-end test and log correlation                               |
| [`06-ibm-cloud-logs/`](06-ibm-cloud-logs/)                                   | Ship ROCKS + VSI logs to IBM Cloud Logs                           |
| [`docs/demo-runbook-ibm-cloud-logs.md`](docs/demo-runbook-ibm-cloud-logs.md) | Where to call each MS + expected Logs UI output                   |

## Quick start

1. Build and push images: [`microservices/build-and-push.sh`](microservices/build-and-push.sh)
2. Install operator: [`01-setup/`](01-setup/)
3. Install ambient mesh: [`02-ambient-mesh/`](02-ambient-mesh/)
4. Deploy cluster services: [`03-deploy-microservices/`](03-deploy-microservices/)
5. Onboard VSI with istio-sidecar.rpm: [`04-vsi-sidecar/`](04-vsi-sidecar/)
6. Verify traces: [`05-verify-and-trace/`](05-verify-and-trace/)
7. IBM Cloud Logs: [`06-ibm-cloud-logs/`](06-ibm-cloud-logs/)

## Sidecar mode note

All three services use Envoy **sidecar** injection (not ambient ztunnel):
- **ms-a** and **ms-b** run on the cluster with `sidecar.istio.io/inject: "true"` and `ambient.istio.io/redirection: disabled`
- **ms-c** runs on the VSI with `istio-sidecar.rpm`

This is required because the EW gateway (`HBONEPort: 0`) does not relay HBONE connections from external VMs to ambient pods.  
Istiod correctly pushes the EW gateway's external IPs (port 15443, `AUTO_PASSTHROUGH`) as endpoints to the VM proxy when destination pods have `TLSMode: istio` (sidecar mode).

## Chain verification

```bash
MS_A_URL="https://ms-a-osm-poc-demo.<cluster-domain>"

# Health
curl -sk ${MS_A_URL}/health

# Full chain A → B → C → A (expect HTTP 200 in ~1-2 s)
curl -sk ${MS_A_URL}/api/run-chain
```

Expected JSON response shows all 4 services responding with the same `traceId`:
```json
{
  "service": "ms-a",
  "traceId": "<uuid>",
  "result": "...ms-b...ms-c...ms-a handled request from ms-c..."
}
```

## Requirements mapping (client checklist)

| #   | Requirement                                    | Location                                                                                                             |
| --- | ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| 1   | 3 Java MS, Red Hat OpenJDK, Routes / localhost | `microservices/`, Routes in `03-deploy-microservices/04-services-routes.yaml`                                       |
| 2   | A→B, B→C, C→A only                             | `docs/communication-policy.md`, `06-authorization-policies.yaml`                                                    |
| 3   | A,B on ROCKS; C on VSI                         | `docs/architecture-deployment.md`                                                                                    |
| 4   | Deployment diagram                             | `docs/architecture-deployment.md`                                                                                    |
| 5   | Authorization diagram                          | `docs/communication-policy.md`                                                                                       |
| 6   | OSM ambient + ms-a/ms-b procedure              | `02-ambient-mesh/`, `03-deploy-microservices/`                                                                       |
| 7   | VSI sidecar + mesh join                        | `04-vsi-sidecar/`                                                                                                    |
| 8   | Traceable logs                                 | JSON logs + `X-Trace-Id`; `05-verify-and-trace/`, `06-ibm-cloud-logs/`                                              |
| 9   | Code + Containerfile + Quay script             | `microservices/`                                                                                                     |
| 10  | All Deployment manifests                       | `03-deploy-microservices/`                                                                                           |

## Official documentation

- [OSM 3.3 Installing](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/index)
- [Istio ambient mode (OSM 3.3)](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode)
- [Integrate external Linux VMs with OSM](https://developers.redhat.com/articles/2026/04/17/integrate-red-hat-enterprise-linux-vms-openshift-service-mesh)
- [OSM 3.3 Release notes](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/release_notes/ossm-release-notes)
