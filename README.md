# PoC: OpenShift Service Mesh 3.2 — Ambient Mode with ROCKS + IBM Cloud VSI

## Summary

Demonstrates **OpenShift Service Mesh (OSM) 3.2** in **Istio ambient mode** on a **ROCKS** cluster (OpenShift on IBM Cloud) with two Java microservices in-cluster (**ms-a**, **ms-b**) and a third (**ms-c**) on an **IBM Cloud VSI**, joined via **ztunnel** and multi-network east-west gateway. Traffic follows a strict ring **A → B → C → A** enforced by L4 `AuthorizationPolicy` and correlated by `X-Trace-Id` logs.

## Environment

| Item | Value |
|---|---|
| OpenShift | 4.19+ (ROCKS on IBM Cloud) |
| Service Mesh | OSM **3.2** (Sail Operator, ambient profile) |
| CNI | OVN-Kubernetes (`routingViaHost: true`) |
| Edge | IBM Cloud **VSI** (RHEL 9) |
| Images | `registry.access.redhat.com/ubi9/openjdk-21-runtime` → Quay.io |

## Architecture diagrams

- [Deployment placement (ROCKS vs VSI)](docs/architecture-deployment.md)
- [Communication matrix and policies](docs/communication-policy.md)

## Repository structure

| Folder | Purpose |
|---|---|
| [`microservices/`](microservices/) | Java source, Containerfiles, Quay build script |
| [`01-setup/`](01-setup/) | Sail Operator subscription, mesh namespaces |
| [`02-ambient-mesh/`](02-ambient-mesh/) | Istio / IstioCNI / ZTunnel CRs, east-west gateway |
| [`03-deploy-microservices/`](03-deploy-microservices/) | ms-a & ms-b Deployments, Routes, policies, WorkloadEntry for ms-c |
| [`04-vsi-ztunnel/`](04-vsi-ztunnel/) | VSI ztunnel install scripts, ms-c runbook |
| [`05-verify-and-trace/`](05-verify-and-trace/) | End-to-end test and log correlation |
| [`06-ibm-cloud-logs/`](06-ibm-cloud-logs/) | Ship ROCKS + VSI logs to IBM Cloud Logs |
| [`docs/demo-runbook-ibm-cloud-logs.md`](docs/demo-runbook-ibm-cloud-logs.md) | Where to call each MS + expected Logs UI output |

## Quick start

1. Build and push images: [`microservices/build-and-push.sh`](microservices/build-and-push.sh)
2. Install operator: [`01-setup/`](01-setup/)
3. Install ambient mesh: [`02-ambient-mesh/`](02-ambient-mesh/)
4. Deploy cluster services: [`03-deploy-microservices/`](03-deploy-microservices/) (`export QUAY_ORG=...` before `envsubst`)
5. Onboard VSI: [`04-vsi-ztunnel/`](04-vsi-ztunnel/)
6. Verify traces: [`05-verify-and-trace/`](05-verify-and-trace/)
7. IBM Cloud Logs: [`06-ibm-cloud-logs/`](06-ibm-cloud-logs/) — demo queries in [`docs/demo-runbook-ibm-cloud-logs.md`](docs/demo-runbook-ibm-cloud-logs.md)

## Requirements mapping (client checklist)

| # | Requirement | Location |
|---|---|---|
| 1 | 3 Java MS, Red Hat OpenJDK, Routes / localhost | [`microservices/`](microservices/), Routes in `03-deploy-microservices/04-services-routes.yaml` |
| 2 | A→B, B→C, C→A only | [`docs/communication-policy.md`](docs/communication-policy.md), `06-authorization-policies.yaml` |
| 3 | A,B on ROCKS; C on VSI | [`docs/architecture-deployment.md`](docs/architecture-deployment.md) |
| 4 | Deployment diagram | [`docs/architecture-deployment.md`](docs/architecture-deployment.md) |
| 5 | Authorization diagram | [`docs/communication-policy.md`](docs/communication-policy.md) |
| 6 | OSM ambient + ms-a/ms-b procedure | [`02-ambient-mesh/`](02-ambient-mesh/), [`03-deploy-microservices/`](03-deploy-microservices/) |
| 7 | VSI ztunnel + mesh join | [`04-vsi-ztunnel/`](04-vsi-ztunnel/) |
| 8 | Traceable logs | JSON logs + `X-Trace-Id`; [`05-verify-and-trace/`](05-verify-and-trace/), [`06-ibm-cloud-logs/`](06-ibm-cloud-logs/) |
| 9 | Code + Containerfile + Quay script | [`microservices/`](microservices/) |
| 10 | All Deployment manifests | [`03-deploy-microservices/`](03-deploy-microservices/) |

## Official documentation

- [OSM 3.2 Installing](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/installing/index)
- [Istio ambient mode (OSM 3.2)](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/installing/ossm-istio-ambient-mode)
- [OSM 3.2 Release notes (ambient GA)](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html-single/release_notes/index)
- [Integrate external Linux VMs](https://developers.redhat.com/articles/2026/04/17/integrate-red-hat-enterprise-linux-vms-openshift-service-mesh)

## Important notes

- Align `ZTUNNEL_VERSION` / Istio version on the VSI with the operator-deployed control plane.
- External VM integration with ambient ztunnel is an advanced scenario; validate on your ROCKS build. Red Hat documents VM onboarding in depth for OSM 3.3+ Developer Preview — this PoC follows the same Istio patterns (WorkloadEntry, east-west gateway, dedicated ztunnel).
- Replace `VSI_PRIVATE_IP` and `QUAY_ORG` placeholders before production demos.
