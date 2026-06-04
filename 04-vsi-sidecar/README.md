# Step 4 — VSI Sidecar onboarding (istio-sidecar.rpm)

This step registers the IBM Cloud VSI (`ms-c`) into the OpenShift Service Mesh using the
Red Hat–provided `istio-sidecar.rpm`. This is the approach documented in:
[Integrate Red Hat Enterprise Linux VMs with OpenShift Service Mesh](https://developers.redhat.com/articles/2026/04/17/integrate-red-hat-enterprise-linux-vms-openshift-service-mesh)

---

## Prerequisites (done once, outside the repo)

| Item | Notes |
|------|-------|
| RHEL 9.6+ VSI | Reachable from the cluster via its public IP |
| ROCKS 4.20+ cluster | Istio Ambient deployed (steps 1–3) |
| `istio-sidecar.rpm` | Download from Red Hat Customer Portal and SCP to `/tmp/istio-sidecar.rpm` on the VSI |

---

## Overview

```
[VSI: ms-c]                         [Cluster: main-network]
   Envoy sidecar (istio-sidecar.rpm)
        │
        │  mTLS over port 15443
        ▼
[East-West Gateway (LoadBalancer)]
        │
        │  AUTO_PASSTHROUGH SNI routing
        ▼
[ms-a sidecar]  [ms-b sidecar]
```

- **ms-c** runs on the VSI with the standard `istio-sidecar.rpm` (Envoy proxy + `pilot-agent`)
- Outbound traffic from ms-c to cluster services is intercepted by iptables → Envoy → EW gateway:15443
- Inbound traffic to ms-c from the cluster arrives at its public IP → PREROUTING redirect to Envoy:15006
- The VSI registers automatically via `WorkloadGroup` auto-registration

---

## Step 4.1 — Install istio-sidecar.rpm on the VSI

```bash
# Download on your workstation (requires Red Hat account)
OSSM_VERSION=1.28.6
curl -L -o /tmp/istio-sidecar-${OSSM_VERSION}.rpm \
  "https://access.redhat.com/.../istio-sidecar-${OSSM_VERSION}.rpm"

# Copy to VSI (VSI has no internet access)
scp /tmp/istio-sidecar-${OSSM_VERSION}.rpm vpcuser@<VSI_PUBLIC_IP>:/tmp/istio-sidecar.rpm

# Install on VSI
ssh vpcuser@<VSI_PUBLIC_IP> 'sudo rpm -ivh /tmp/istio-sidecar.rpm'
```

---

## Step 4.2 — Create ServiceAccount, WorkloadGroup, and ServiceEntry on cluster

```bash
oc apply -f ../03-deploy-microservices/05-workload-c.yaml
```

This creates:
- `ServiceAccount/ms-c` in `osm-poc-demo`
- `WorkloadGroup/ms-c` — template for auto-registration
- `Service/ms-c` — ClusterIP service for cluster→VM traffic
- `ServiceEntry/ms-c` — mesh-internal service entry resolved from WorkloadEntry

---

## Step 4.3 — Generate identity artifacts

Use `istioctl` to generate the onboarding files. The command reads the WorkloadGroup
and the EW gateway's LoadBalancer IP to populate `cluster.env`, `mesh.yaml`, `hosts`,
`root-cert.pem`, and `istio-token`.

```bash
# Get EW gateway external address
GW_HOSTNAME=$(oc get svc istio-eastwestgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
GW_IP=$(dig +short $GW_HOSTNAME | head -1)

mkdir -p /tmp/vm-bootstrap-ms-c

# Extract the WorkloadGroup alone (required by istioctl)
oc get workloadgroup ms-c -n osm-poc-demo -o yaml > /tmp/ms-c-workloadgroup.yaml

istioctl x workload entry configure \
  -f /tmp/ms-c-workloadgroup.yaml \
  -o /tmp/vm-bootstrap-ms-c \
  --clusterID rocks-cluster \
  --ingressIP "$GW_IP"
```

---

## Step 4.4 — Append VM-specific overrides to cluster.env

The `istio-start.sh` auto-detects the private NIC IP. Override it with the VSI public IP
and disable HBONE (the EW gateway exposes only port 15443 for mTLS, not 15008):

```bash
cat >> /tmp/vm-bootstrap-ms-c/cluster.env <<EOF
INSTANCE_IP='<VSI_PUBLIC_IP>'
ISTIO_SVC_IP='<VSI_PUBLIC_IP>'
ISTIO_META_ENABLE_HBONE='false'
EOF
```

---

## Step 4.5 — Refresh the istio-token (OpenShift-compatible)

```bash
oc create token ms-c -n osm-poc-demo \
  --audience=istio-ca \
  --duration=86400s \
  > /tmp/vm-bootstrap-ms-c/istio-token
```

---

## Step 4.6 — Copy artifacts to VSI and start the sidecar

```bash
ssh vpcuser@<VSI_PUBLIC_IP> 'sudo mkdir -p /var/lib/istio/envoy /etc/certs /var/run/secrets/tokens'

scp /tmp/vm-bootstrap-ms-c/cluster.env   vpcuser@<VSI_PUBLIC_IP>:/var/lib/istio/envoy/cluster.env
scp /tmp/vm-bootstrap-ms-c/mesh.yaml     vpcuser@<VSI_PUBLIC_IP>:/etc/istio/config/mesh
scp /tmp/vm-bootstrap-ms-c/root-cert.pem vpcuser@<VSI_PUBLIC_IP>:/etc/certs/root-cert.pem
scp /tmp/vm-bootstrap-ms-c/istio-token   vpcuser@<VSI_PUBLIC_IP>:/var/run/secrets/tokens/istio-token

# Append EW-GW → istiod hostname resolution
ssh vpcuser@<VSI_PUBLIC_IP> "echo '${GW_IP} istiod.istio-system.svc' | sudo tee -a /etc/hosts"

# Enable and start the sidecar
ssh vpcuser@<VSI_PUBLIC_IP> 'sudo systemctl enable --now istio'
ssh vpcuser@<VSI_PUBLIC_IP> 'sudo systemctl status istio --no-pager | head -10'
```

---

## Step 4.7 — Verify auto-registration

```bash
# WorkloadEntry should appear within seconds
oc get workloadentry -n osm-poc-demo

# Confirm VM is in proxy-status
istioctl proxy-status | grep vm-network
```

Expected:
```
NAME                                  CLUSTER        ISTIOD                VERSION
vsi-jwims.osm-poc-demo                rocks-cluster  istiod-xxxxx          1.28.6
```

---

## Step 4.8 — Start ms-c application on VSI

```bash
ssh vpcuser@<VSI_PUBLIC_IP> \
  'nohup sudo -u ms-c java -Djava.net.preferIPv4Stack=true \
   -jar /opt/osm-poc/ms-c.jar \
   > /tmp/ms-c-app.log 2>&1 &'
```

---

## Verification

From any host with access to the cluster Route:

```bash
MS_A_URL="https://ms-a-osm-poc-demo.<cluster-domain>"

# Health check
curl -sk ${MS_A_URL}/health

# Full chain: A → B → C → A
curl -sk ${MS_A_URL}/api/run-chain
```

Expected response (HTTP 200, ~1–2 s):
```json
{
  "service": "ms-a",
  "traceId": "<uuid>",
  "result": "{\"service\":\"ms-b\", ... \"downstream\":\"{\\\"service\\\":\\\"ms-c\\\", ... \\\"downstream\\\":\\\"{\\\"service\\\":\\\"ms-a\\\",\\\"message\\\":\\\"ms-a handled request from ms-c\\\"}\\\"}\"}\"}"
}
```
