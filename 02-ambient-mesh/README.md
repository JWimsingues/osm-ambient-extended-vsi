# Step 2 — Install OSM 3.3 Ambient Mode

## Summary

Deploys the Istio ambient data plane on ROCKS: `Istio` control plane, `IstioCNI`, cluster `ZTunnel` DaemonSet, and multi-network settings for extending the mesh to an IBM Cloud VSI (`main-network` / `vsi-network`). Also deploys an east-west gateway so the VSI can reach `istiod` and mesh workloads.

## Prerequisites

- Step [`01-setup`](../01-setup/) completed; Sail Operator is `Available`
- Gateway API CRDs present on the cluster (shipped with OpenShift 4.19+)
- Replace placeholders in manifests:
  - `MESH_ID` (default `mesh1`)
  - East-west gateway public IP / DNS after LoadBalancer is provisioned
- Namespaces included in mesh discovery must carry `istio-discovery=enabled` (see `01-setup/02-namespaces.yaml`, `03-deploy-microservices/01-namespace.yaml`). `01-istio-ambient.yaml` scopes istiod with matching `discoverySelectors`.

## Steps

1. Apply ambient control plane resources:

   ```bash
   cd 02-ambient-mesh
   oc apply -f 01-istio-ambient.yaml
   oc apply -f 02-istio-cni-ambient.yaml
   oc apply -f 03-ztunnel.yaml
   ```

2. Wait for components to become ready:

   ```bash
   oc wait --for=condition=Ready istio/default -n istio-system --timeout=10m
   oc wait --for=condition=Ready istiocni/default -n istio-cni --timeout=10m
   oc wait --for=condition=Ready ztunnel/default -n ztunnel --timeout=10m
   oc -n ztunnel get pods
   ```

3. Deploy east-west gateway and expose `istiod` (multi-network / VSI onboarding):

   ```bash
   oc apply -f 04-eastwest-gateway.yaml
   oc -n istio-system rollout status deploy/istio-eastwestgateway --timeout=5m
   oc apply -f 05-expose-istiod.yaml
   oc apply -f 06-expose-istiod-lb.yaml
   oc label namespace istio-system topology.istio.io/network=main-network --overwrite
   oc -n istio-system rollout status deploy/istiod --timeout=5m
   ```

4. Record the east-west gateway address (used on the VSI):

   ```bash
   export EW_GATEWAY_HOST=$(oc -n istio-system get svc istio-eastwestgateway \
     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   export ISTIOD_GATEWAY_HOST=$(oc -n istio-system get svc istiod-xds-external \
     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   echo "EW_GATEWAY_HOST=${EW_GATEWAY_HOST}"
   echo "ISTIOD_GATEWAY_HOST=${ISTIOD_GATEWAY_HOST}"
   ```

   `meshNetworks` must define **main-network** (not `vsi-network`) so VSI ztunnel routes cross-network traffic through the east-west gateway on port **15008**, not directly to pod IPs.

5. Label the application project for ambient dataplane (if `03-deploy-microservices` is not applied yet, or labels were missing):

   ```bash
   oc label namespace osm-poc-demo istio.io/dataplane-mode=ambient --overwrite
   oc label namespace osm-poc-demo istio-discovery=enabled --overwrite
   ```

   Both labels are already set in `03-deploy-microservices/01-namespace.yaml`; `istio-discovery=enabled` is required for `discoverySelectors` on the `Istio` CR.

6. Verify ambient control plane and multi-network (required for VSI):

   ```bash
   ./verify-ambient.sh
   istioctl ztunnel-config workloads -n ztunnel | head
   ```

   `verify-ambient.sh` fails if `meshNetworks` or `AMBIENT_ENABLE_MULTI_NETWORK` is missing on the live `Istio` CR.

## Expected (Working) Output

```text
istio/default condition=Ready
ztunnel/default condition=Ready
ztunnel-xxxxx   1/1   Running
istio-eastwestgateway-xxxxx   2/2   Running
```

## Official Documentation

- [Installing Istio ambient mode (OSM 3.2)](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/installing/ossm-istio-ambient-mode)
- [Configuring network policies for ambient mode](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/installing/ossm-configuring-network-policies-ambient)
- [Integrate Linux VMs into OpenShift Service Mesh](https://developers.redhat.com/articles/2026/04/17/integrate-red-hat-enterprise-linux-vms-openshift-service-mesh)

## Alternatives Considered

| Approach | Notes |
|---|---|
| Ambient + ztunnel on VSI (this PoC) | Sidecar-less on cluster; dedicated ztunnel on VSI for L4 mTLS and AuthorizationPolicy |
| Sidecar on VSI | Mature VM onboarding path; higher footprint on the VSI |
| ServiceEntry only (no ztunnel on VSI) | Simpler routing but no mesh identity or L4 policy on the VSI workload |
