# Step 4 — Extend Ambient Mesh to IBM Cloud VSI (ms-c + ztunnel)

## Summary

Onboards **ms-c** running on an IBM Cloud VSI into the ROCKS ambient mesh by installing a **dedicated ztunnel** on the VSI (not a sidecar), registering a `WorkloadEntry`, and pointing xDS/certificate traffic to the cluster **east-west gateway**. Application traffic uses mesh DNS names (`ms-a.osm-poc-demo.svc.cluster.local`) over HBONE/mTLS.

## Prerequisites

- Steps 1–3 completed; `EW_GATEWAY_HOST` recorded from step 2
- RHEL 9.x VSI with outbound connectivity to the east-west gateway (TCP `15012`, `15017`, `15008`)
- Inbound from cluster to VSI on TCP `8080` (and `15008` if required by your network design)
- `istioctl` on your workstation; `sudo` on the VSI (default login is not root)
- ztunnel **1.28.6** matching OSM **3.3** / Istio **1.28.6** (the install script pulls `docker.io/istio/ztunnel:1.28.6` and extracts the binary)
- IBM Cloud VPC security group rules updated so you can SSH to the VSI (see step 1)

## Steps

### 1. Allow SSH from your workstation (IBM Cloud VPC)

In the VPC security group attached to the VSI, add an **inbound** rule:

| Field | Value |
| --- | --- |
| Protocol | TCP |
| Port range | Minimum **22** / Maximum **22** |
| Source type | CIDR block |
| Source | Your public IP with `/32` (for example `203.0.113.10/32`) |

To discover your public IP from a local terminal:

```bash
curl -s ifconfig.me && echo
```

For short-lived lab testing only, you may use `0.0.0.0/0` (anywhere). Restricting to your own `/32` is strongly recommended.

Also allow mesh traffic as needed (step 8): inbound TCP **15008** (HBONE) and **8080** from the cluster network.

### 2. Connect to the VSI (RHEL default user `vpcuser`)

On your workstation, restrict the SSH private key permissions and connect. Replace placeholders with your key path and VSI public IP.

```bash
chmod 400 <path-to-your-key>.prv
ssh -i <path-to-your-key>.prv vpcuser@<VSI_PUBLIC_IP>
```

RHEL images on IBM Cloud use **`vpcuser`**, not `root`. See [Connecting to a Linux VSI](https://cloud.ibm.com/docs/vpc?topic=vpc-vsi_is_connecting_linux&interface=ui).

Example:

```bash
chmod 400 jwimsing_rsa.prv
ssh -i jwimsing_rsa.prv vpcuser@161.156.86.195
```

Use `sudo` for package installation and systemd on the VSI.

### 3. Prepare the VSI (OS packages)

```bash
sudo dnf install -y podman java-21-openjdk-headless
sudo useradd --system --gid 1000 --home-dir /var/lib/istio istio-proxy 2>/dev/null || true
```

### 4. Generate workload onboarding files (workstation)

```bash
cd 04-vsi-ztunnel
export EW_GATEWAY_HOST="<east-west-gateway-hostname>"
export VSI_PRIVATE_IP="<vsi-private-ip>"

oc apply -f ../03-deploy-microservices/05-workload-c.yaml
# Edit WorkloadEntry address in 05-workload-c.yaml if not set already

istioctl x workload entry configure \
  -f ../03-deploy-microservices/05-workload-c.yaml \
  --clusterID rocks-cluster \
  -o ./vsi-onboarding \
  --tokenDuration=86400
```

`--tokenDuration` must be an **integer number of seconds** (not `24h`). `86400` is 24 hours. Default is `3600` (1 hour).

### 5. Copy onboarding files and install script to the VSI (workstation)

From your workstation (replace key path and VSI IP). IBM Cloud RHEL images use **`vpcuser`**; files land under `/home/vpcuser/`:

```bash
cd 04-vsi-ztunnel
scp -i <path-to-your-key>.prv -r \
  ./scripts/install-ztunnel.sh \
  ./vsi-onboarding \
  vpcuser@<VSI_PUBLIC_IP>:/home/vpcuser/
```

Example:

```bash
scp -i jwimsing_rsa.prv -r \
  ./scripts/install-ztunnel.sh \
  ./vsi-onboarding \
  vpcuser@161.156.86.195:/home/vpcuser/
```

### 6. Install ztunnel on the VSI

SSH to the VSI as `vpcuser`, then run the install script. It pulls `istio/ztunnel:1.28.6`, copies onboarding files from `/home/vpcuser/vsi-onboarding`, and maps `istiod` to the east-west gateway in `/etc/hosts`.

```bash
ssh -i <path-to-your-key>.prv vpcuser@<VSI_PUBLIC_IP>
cd /home/vpcuser
export EW_GATEWAY_HOST="<east-west-gateway-hostname>"
export ZTUNNEL_VERSION="1.28.6"   # OSM 3.3 / Istio 1.28.6
sudo -E ./install-ztunnel.sh
```

### 7. Start ztunnel (systemd)

```bash
sudo systemctl enable --now ztunnel
sudo systemctl status ztunnel
```

### 8. Deploy ms-c container on the VSI

```bash
export QUAY_ORG=your-quay-org
export IMAGE_TAG=latest
export MS_A_URL="http://ms-a.osm-poc-demo.svc.cluster.local:8080"

sudo podman run -d --name ms-c --restart=always \
  -p 127.0.0.1:8080:8080 \
  -e MS_A_URL="${MS_A_URL}" \
  -e BIND_HOST=0.0.0.0 \
  quay.io/${QUAY_ORG}/osm-poc-ms-c:${IMAGE_TAG}
```

If the image is private, run `sudo podman login quay.io` on the VSI first (or use a pull secret workflow).

Expose on localhost for local demos (`curl localhost:8080/health`). Mesh traffic arrives via ztunnel redirection on port 8080.

### 9. Verify mesh connectivity

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

### 10. Network policy reminder

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
- [Connecting to a Linux VSI (IBM Cloud)](https://cloud.ibm.com/docs/vpc?topic=vpc-vsi_is_connecting_linux&interface=ui)

## Alternatives Considered

| Approach | Notes |
|---|---|
| Dedicated ztunnel on VSI | Matches ambient architecture; L4 policies enforced on VSI |
| Sidecar (istio-proxy) on VSI | Well-documented VM guide; not sidecar-less |
| ServiceEntry without proxy | No mesh identity; unsuitable for mTLS demo |
