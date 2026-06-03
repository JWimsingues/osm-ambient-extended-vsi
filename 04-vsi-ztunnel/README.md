# Step 4 — Extend Ambient Mesh to IBM Cloud VSI (ms-c + ztunnel)

## Summary

Onboards **ms-c** running on an IBM Cloud VSI into the ROCKS ambient mesh by installing a **dedicated ztunnel** on the VSI (not a sidecar), registering a `WorkloadEntry`, and pointing xDS/certificate traffic to the cluster **east-west gateway**. Application traffic uses mesh DNS names (`ms-a.osm-poc-demo.svc.cluster.local`) over HBONE/mTLS.

## Prerequisites

- Steps 1–3 completed; `EW_GATEWAY_HOST` recorded from step 2
- RHEL 9.x VSI with outbound connectivity to the east-west gateway (TCP `15012`, `15017`, `15008`)
- Inbound from cluster to VSI on TCP `8080` (and `15008` if required by your network design)
- `istioctl` on your workstation; `sudo` on the VSI (default login is not root)
- ztunnel **1.28.6** matching OSM **3.3** / Istio **1.28.6** (the install script pulls `docker.io/istio/ztunnel:1.28.6` and runs it with **Podman** and host networking — do not copy the binary to the host; the image needs **glibc 2.38**, which many RHEL 9 VSIs do not have)
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

SSH to the VSI as `vpcuser`, then run the install script. It pulls `istio/ztunnel:1.28.6`, installs a **Podman-based** systemd unit (host network), copies onboarding files from `/home/vpcuser/vsi-onboarding`, and maps `istiod` to the east-west gateway in `/etc/hosts`.

```bash
ssh -i <path-to-your-key>.prv vpcuser@<VSI_PUBLIC_IP>
cd /home/vpcuser
export EW_GATEWAY_HOST="<east-west-gateway-hostname>"
export ZTUNNEL_VERSION="1.28.6"   # OSM 3.3 / Istio 1.28.6
sudo -E ./install-ztunnel.sh
# Or pass the hostname as an argument (works with plain sudo; no -E needed):
# sudo ./install-ztunnel.sh "<east-west-gateway-hostname>"
# Re-runs read /etc/istio/ew-gateway.env if the variable is omitted.
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
  --network host \
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

## Troubleshooting

### `istioctl ztunnel-config service` shows `ms-c` with `0/0` endpoints

The Kubernetes `Service` for ms-c has **no pod selector**, so the ClusterIP has no backends until an **`EndpointSlice`** points at the VSI IP (see `03-deploy-microservices/05-workload-c.yaml`). A `ServiceEntry` with `workloadSelector` alone is **not** sufficient in ambient mode — you need the VIP wired to `10.243.64.9`.

Apply (set `WorkloadEntry` + `EndpointSlice` address to your VSI private IP):

```bash
oc apply -f 03-deploy-microservices/05-workload-c.yaml
```

Confirm (must show **1/1**, not 0/0):

```bash
istioctl ztunnel-config service -n ztunnel | grep ms-c
```

If you previously created a standalone `ServiceEntry` named `ms-c`, delete it to avoid confusion:

```bash
oc -n osm-poc-demo delete serviceentry ms-c --ignore-not-found
```

Test pod must have **both** labels: `istio.io/dataplane-mode=ambient` and `ambient.istio.io/redirection: enabled` (see mesh-curl example above).

### ms-b: `failed to reach ms-c: HTTP/1.1 header parser received no bytes`

ztunnel shows `ms-c-vsi` at the WorkloadEntry IP, but the app gets no HTTP response. Common causes:

1. **`PROXY_WORKLOAD_INFO` name mismatch** — if install used `.../ms-c/ms-c` but `istioctl ztunnel-config workloads` shows `ms-c-vsi`, inbound HBONE never reaches the app. Fix on the VSI:
   ```bash
   sudo sed -i 's|PROXY_WORKLOAD_INFO=osm-poc-demo/ms-c/ms-c|PROXY_WORKLOAD_INFO=osm-poc-demo/ms-c-vsi/ms-c|' \
     /etc/systemd/system/ztunnel.service
   sudo systemctl daemon-reload
   sudo systemctl restart ztunnel
   ```
2. **TCP 15008 blocked** — ambient uses HBONE on **15008**, not plain HTTP to 8080 from the cluster. Allow inbound **15008** (and **8080** if needed) on the VSI security group from worker nodes / east-west gateway.
3. **Wrong WorkloadEntry IP** — `10.243.64.9` must be the VSI private IP (`ip -4 addr` on the VSI).
4. **ms-c not on host network** — recreate with `scripts/run-ms-c.sh` (`--network host`).

Test from an ambient client (same path as ms-b):

```bash
oc -n osm-poc-demo run mesh-curl --rm -i --restart=Never \
  --image=curlimages/curl \
  --overrides='{"metadata":{"labels":{"istio.io/dataplane-mode":"ambient","ambient.istio.io/redirection":"enabled"}}}' \
  --command -- curl -sv --max-time 15 http://ms-c:8080/health
```

`curl` may still print a ClusterIP (e.g. `172.21.x.x`) — that is normal. With ambient redirection, traffic must go through ztunnel to the VSI on **15008**, not to the VIP:8080 directly.

While that runs, on the VSI: `sudo podman logs -f ztunnel` — you should see **inbound/HBONE** log lines (not only `workload.Address` updates). If there is no inbound activity, packets never reach the VSI.

**`curl: (7) Could not connect` in ~3 ms** usually means no TCP listener or no route (wrong IP, security group, or endpoint removed from xDS). **`Connection reset by peer`** from `oc rsh deploy/ms-b` often means something answered then closed (ztunnel rejecting non-HBONE traffic, or a flaky endpoint).

Run these in order:

```bash
# 1) WorkloadEntry stable and IP correct
oc -n osm-poc-demo get workloadentry ms-c-vsi -o wide
watch -n2 'oc -n osm-poc-demo get workloadentry'

# 2) meshNetworks + multi-network enabled (re-apply if unsure)
oc apply -f 02-ambient-mesh/01-istio-ambient.yaml
oc -n istio-system rollout status deploy/istiod --timeout=5m

# 3) Raw TCP from cluster to VSI (bypasses HTTP; use your WE address)
oc -n osm-poc-demo run netshoot --rm -i --restart=Never \
  --image=nicolaka/netshoot --command -- \
  sh -c 'nc -zv 10.243.64.9 15008; nc -zv 10.243.64.9 8080'
```

On the **VSI** (replace IP if different):

```bash
ip -4 addr
ss -lntp | grep -E '15008|8080'
sudo podman ps
curl -s http://127.0.0.1:8080/health
grep PROXY_WORKLOAD_INFO /etc/systemd/system/ztunnel.service
# Must be: osm-poc-demo/ms-c-vsi/ms-c
```

**IBM VPC security group (VSI):** inbound TCP **15008** and **8080** from the **ROCKS worker subnet** (and east-west gateway path). Without **15008**, ambient mesh traffic never reaches ztunnel.

For **ms-c → ms-a** failures, also check: ms-c on **host network**, `meshNetworks` applied (`02-ambient-mesh/01-istio-ambient.yaml`), and mesh DNS via ztunnel.

### `curl` to `127.0.0.1:8080/api/call-a` → `Empty reply from server`

`/health` may work while `/api/call-a` fails: the handler calls `ms-a.osm-poc-demo.svc.cluster.local`, which requires **ztunnel DNS** on the VSI. Without it, the JVM can misbehave or the connection can be reset by redirection.

On the VSI:

```bash
# 1) ms-c still healthy?
curl -s http://127.0.0.1:8080/health

# 2) mesh DNS via ztunnel (must answer with an IP)
ss -lntp | grep 15053
getent hosts ms-a.osm-poc-demo.svc.cluster.local
# or: dig @127.0.0.1 -p 15053 ms-a.osm-poc-demo.svc.cluster.local +short

# 3) ms-c logs for the request (expect CALL_A or an error)
grep "${TRACE}" /var/log/osm-poc/ms-c.log
sudo podman logs ms-c 2>&1 | tail -30
```

ztunnel serves mesh DNS on **127.0.0.1:15053**, but `getent` / Java use **port 53**. You need a local forwarder plus `resolv.conf` (the install script sets this up via `ztunnel-dns-forward.service`).

Quick check — DNS works on 15053?

```bash
dig @127.0.0.1 -p 15053 ms-a.osm-poc-demo.svc.cluster.local +short
```

If that returns IPs but `getent` fails, apply the forwarder (run as root on the VSI):

```bash
sudo dnf install -y socat
sudo tee /etc/resolv.conf <<'EOF'
nameserver 127.0.0.1
search osm-poc-demo.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
EOF
sudo tee /etc/systemd/system/ztunnel-dns-forward.service <<'EOF'
[Unit]
Description=Forward local DNS :53 to ztunnel :15053
After=ztunnel.service
Requires=ztunnel.service
[Service]
ExecStart=/usr/bin/socat UDP4-LISTEN:53,bind=127.0.0.1,reuseaddr,fork UDP4:127.0.0.1:15053
Restart=always
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now ztunnel-dns-forward
getent hosts ms-a.osm-poc-demo.svc.cluster.local
```

Then retry `curl -H "X-Trace-Id: ${TRACE}" http://127.0.0.1:8080/api/call-a`.

**Authoritative C→A test (same code path as the chain):** trigger `CALL_A` from the cluster instead of localhost:

```bash
export TRACE=$(uuidgen | tr '[:upper:]' '[:lower:]')
oc rsh -n osm-poc-demo deploy/ms-b -- \
  curl -sv -H "X-Trace-Id: ${TRACE}" http://ms-c:8080/api/handle-from-b
oc -n osm-poc-demo logs deploy/ms-a --since=5m | grep "${TRACE}"
grep "${TRACE}" /var/log/osm-poc/ms-c.log   # on VSI
```

Pass = ms-c log shows `CALL_A`, ms-a log shows `FROM_C`, curl returns HTTP 200.

Checks on the VSI:

```bash
sudo systemctl status ztunnel
sudo podman logs ztunnel 2>&1 | tail -30
ss -lntp | grep -E '15008|15053|8080'
curl -s http://127.0.0.1:8080/health
getent hosts ms-a.osm-poc-demo.svc.cluster.local || true
```

Checks on the cluster:

```bash
oc -n osm-poc-demo get workloadentry ms-c-vsi -o yaml
istioctl ztunnel-config workloads -n ztunnel | grep -E 'ms-c|ms-a'
oc -n istio-system get svc istio-eastwestgateway
```

### ztunnel: `XDS client connection error` / `source: dns error` for `istiod.istio-system.svc:15012`

The VSI cannot resolve cluster DNS. `istiod` must reach the **east-west gateway** on TCP **15012** (not the in-cluster Service IP).

1. Set `EW_GATEWAY_HOST` to the LB hostname from `oc -n istio-system get svc istio-eastwestgateway`.
2. Re-run `install-ztunnel.sh` — it resolves that hostname to an **IPv4 address**, updates `/etc/hosts`, and mounts it into the ztunnel container (`--add-host` as fallback).
3. Confirm outbound **15012** is allowed from the VSI security group.

On the VSI:

```bash
getent hosts istiod.istio-system.svc
curl -vk --resolve istiod.istio-system.svc:15012:$(getent hosts istiod.istio-system.svc | awk '{print $1}') \
  https://istiod.istio-system.svc:15012/ 2>&1 | head -20
sudo systemctl restart ztunnel
sudo podman logs ztunnel 2>&1 | tail -20
```

You should see `istiod.istio-system.svc` map to the gateway IP, and ztunnel logs should stop repeating DNS errors (replaced by TLS/xDS messages).

### ztunnel: `invalid peer certificate: UnknownIssuer` on `:15012`

DNS is working; ztunnel does not trust the certificate presented by istiod (via the east-west gateway). It must load the **mesh root CA** from `/var/run/secrets/istio/root-cert.pem` (not only `/etc/certs/`).

On the VSI:

```bash
sudo ls -la /var/run/secrets/istio/root-cert.pem /var/run/secrets/tokens/istio-token
```

If `root-cert.pem` is missing or stale, refresh from the cluster and re-run install:

```bash
# Workstation
oc -n istio-system get cm istio-ca-root-cert \
  -o jsonpath='{.data.root-cert\.pem}' > root-cert.pem
scp -i <key> root-cert.pem vpcuser@<VSI>:/home/vpcuser/vsi-onboarding/

# VSI
sudo cp /home/vpcuser/vsi-onboarding/root-cert.pem /var/run/secrets/istio/root-cert.pem
sudo cp /home/vpcuser/vsi-onboarding/root-cert.pem /etc/certs/root-cert.pem
sudo systemctl restart ztunnel
```

Or regenerate the full onboarding bundle with `istioctl x workload entry configure` (step 4) and `sudo ./install-ztunnel.sh`.

### `GLIBC_2.38' not found` when starting ztunnel

The official `istio/ztunnel` image is built with **glibc 2.38**. If `install-ztunnel.sh` copied `/usr/local/bin/ztunnel` onto the VSI, systemd runs that binary against the **host** libc (often older on IBM Cloud RHEL 9 images).

Check on the VSI:

```bash
ldd --version | head -1
strings /lib64/libc.so.6 | grep GLIBC_ | tail -3
```

**Fix:** Re-run the current `install-ztunnel.sh` (container-based systemd unit), then:

```bash
sudo rm -f /usr/local/bin/ztunnel
sudo systemctl daemon-reload
sudo systemctl restart ztunnel
sudo systemctl status ztunnel
sudo podman logs ztunnel
```

## Alternatives Considered

| Approach | Notes |
|---|---|
| Dedicated ztunnel on VSI | Matches ambient architecture; L4 policies enforced on VSI |
| Sidecar (istio-proxy) on VSI | Well-documented VM guide; not sidecar-less |
| ServiceEntry without proxy | No mesh identity; unsuitable for mTLS demo |
