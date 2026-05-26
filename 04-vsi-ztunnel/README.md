# Step 4 — Extend Ambient Mesh to IBM Cloud VSI (ms-c + ztunnel)

## Summary

Onboards **ms-c** running on an IBM Cloud VSI into the ROCKS ambient mesh by installing a **dedicated ztunnel** on the VSI (not a sidecar), registering a `WorkloadEntry`, and pointing xDS/certificate traffic to the cluster **east-west gateway**. Application traffic uses mesh DNS names (`ms-a.osm-poc-demo.svc.cluster.local`) over HBONE/mTLS.

## Prerequisites

- Steps 1–3 completed; `EW_GATEWAY_HOST` recorded from step 2
- RHEL 9.x VSI with outbound connectivity to the east-west gateway (TCP `15012`, `15017`, `15008`)
- Inbound from cluster to VSI on TCP `8080` (and `15008` if required by your network design)
- `istioctl` on your workstation; `root` or `sudo` on the VSI
- ztunnel binary matching your OSM/Istio version (from the cluster or [Istio ztunnel release](https://github.com/istio/ztunnel))

## Steps

### 1. Prepare the VSI (OS packages)

```bash
ssh root@VSI_PUBLIC_IP
dnf install -y podman java-21-openjdk-headless
useradd --system --gid 1000 --home-dir /var/lib/istio istio-proxy 2>/dev/null || true
```

### 2. Generate workload onboarding files (workstation)

```bash
cd 04-vsi-ztunnel
export EW_GATEWAY_HOST="<east-west-gateway-hostname>"
export VSI_PRIVATE_IP="<vsi-private-ip>"

oc apply -f ../03-deploy-microservices/05-workload-c.yaml
# Edit WorkloadEntry address if not done already

istioctl x workload entry configure \
  -f ../03-deploy-microservices/05-workload-c.yaml \
  --clusterID rocks-cluster \
  -o ./vsi-onboarding \
  --tokenDuration=24h
```

### 3. Install ztunnel on the VSI

Copy `scripts/install-ztunnel.sh` and onboarding artifacts to the VSI, set `EW_GATEWAY_HOST`, then run:

```bash
export EW_GATEWAY_HOST="<east-west-gateway-hostname>"
export ZTUNNEL_VERSION="1.24.2"   # align with your Istio/OSM version
sudo -E ./install-ztunnel.sh
```

### 4. Configure `/etc/hosts` for istiod via east-west gateway

```bash
echo "${EW_GATEWAY_HOST} istiod.istio-system.svc" | sudo tee -a /etc/hosts
```

### 5. Start ztunnel (systemd)

```bash
sudo cp vsi-onboarding/* /var/lib/istio/ztunnel/  # per install script layout
sudo systemctl enable --now ztunnel
sudo systemctl status ztunnel
```

### 6. Deploy ms-c container on the VSI

```bash
export QUAY_ORG=your-quay-org
export IMAGE_TAG=latest
export MS_A_URL="http://ms-a.osm-poc-demo.svc.cluster.local:8080"

podman run -d --name ms-c --restart=always \
  -p 127.0.0.1:8080:8080 \
  -e MS_A_URL="${MS_A_URL}" \
  -e BIND_HOST=0.0.0.0 \
  quay.io/${QUAY_ORG}/osm-poc-ms-c:${IMAGE_TAG}
```

Expose on localhost for local demos (`curl localhost:8080/health`). Mesh traffic arrives via ztunnel redirection on port 8080.

### 7. Verify mesh connectivity

From the cluster:

```bash
oc -n osm-poc-demo run mesh-curl --rm -i --restart=Never \
  --image=curlimages/curl \
  --overrides='{"metadata":{"labels":{"istio.io/dataplane-mode":"ambient"}}}' \
  -- curl -s http://ms-c:8080/health
```

From the VSI:

```bash
curl -s http://127.0.0.1:8080/api/call-a -H "X-Trace-Id: manual-vsi-test"
```

### 8. Network policy reminder

Allow **inbound TCP 15008** (HBONE) and **8080** on the VSI security group / firewall. See [Configuring network policies for ambient mode](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/installing/ossm-configuring-network-policies-ambient).

## Expected (Working) Output

```text
ztunnel.service - active (running)
curl http://127.0.0.1:8080/health -> OK
istioctl ztunnel-config workloads -n ztunnel | grep ms-c
```

## Official Documentation

- [Istio ambient mode (OSM 3.2)](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/installing/ossm-istio-ambient-mode)
- [Integrate Linux VMs into OpenShift Service Mesh](https://developers.redhat.com/articles/2026/04/17/integrate-red-hat-enterprise-linux-vms-openshift-service-mesh)
- [WorkloadEntry](https://istio.io/latest/docs/reference/config/networking/workload-entry/)

## Alternatives Considered

| Approach | Notes |
|---|---|
| Dedicated ztunnel on VSI | Matches ambient architecture; L4 policies enforced on VSI |
| Sidecar (istio-proxy) on VSI | Well-documented VM guide; not sidecar-less |
| ServiceEntry without proxy | No mesh identity; unsuitable for mTLS demo |
