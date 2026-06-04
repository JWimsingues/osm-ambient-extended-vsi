# Step 2 — Install OSM 3.3 Ambient Mode

## Summary

Deploys the Istio ambient data plane on ROCKS: `Istio` control plane, `IstioCNI`, cluster `ZTunnel` DaemonSet, and multi-network settings for extending the mesh to an IBM Cloud VSI (`main-network` / `vm-network`). Also deploys an east-west gateway so the VSI can reach `istiod` and so the VM proxy can reach cluster workloads.

## Prerequisites

- Step [`01-setup`](../01-setup/) completed; Sail Operator is `Available`
- Namespaces carrying `istio-discovery=enabled` are present (see `01-setup/02-namespaces.yaml` and `03-deploy-microservices/01-namespace.yaml`); the `Istio` CR scopes istiod with matching `discoverySelectors`

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

3. Deploy the east-west gateway and label the `istio-system` namespace:

   ```bash
   chmod +x apply-eastwest-gateway.sh
   ./apply-eastwest-gateway.sh
   oc label namespace istio-system topology.istio.io/network=main-network --overwrite
   oc -n istio-system rollout status deploy/istiod --timeout=5m
   ```

   `apply-eastwest-gateway.sh` applies `04-eastwest-gateway.yaml`, which deploys:
   - A sidecar-injected `Deployment` (`istio: eastwestgateway`) acting as the gateway
   - A `LoadBalancer` Service exposing ports 15012 (istiod xDS), 15017 (webhook), 15443 (data plane AUTO_PASSTHROUGH), and 15021 (health)

4. Record the east-west gateway address (used on the VSI in step 4):

   ```bash
   export EW_GATEWAY_HOST=$(oc -n istio-system get svc istio-eastwestgateway \
     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   export EW_GATEWAY_IP=$(dig +short "${EW_GATEWAY_HOST}" | head -1)
   echo "EW_GATEWAY_HOST=${EW_GATEWAY_HOST}"
   echo "EW_GATEWAY_IP=${EW_GATEWAY_IP}"
   ```

5. Label the application project for mesh enrollment (if not yet done before step 3):

   ```bash
   oc label namespace osm-poc-demo istio.io/dataplane-mode=ambient --overwrite
   oc label namespace osm-poc-demo istio-discovery=enabled --overwrite
   ```

   Both labels are already in `03-deploy-microservices/01-namespace.yaml`; this step is only needed if you apply them out of order.

6. Verify ambient control plane and multi-network:

   ```bash
   ./verify-ambient.sh
   ```

   All checks must print `OK`. `verify-ambient.sh` validates `meshNetworks`, `AMBIENT_ENABLE_MULTI_NETWORK`, the ztunnel DaemonSet, and the east-west gateway Deployment and LoadBalancer Service.

## Expected Output

```text
OK:    istio/default Ready
OK:    meshNetworks present on Istio CR
OK:    meshNetworks defines main-network (VM sidecar routes C→A via EW gateway port 15443)
OK:    istiod AMBIENT_ENABLE_MULTI_NETWORK=true
OK:    istiod rolled out
OK:    ztunnel pods Running (cluster DaemonSet)
OK:    east-west gateway Deployment present (istio-system)
OK:    east-west gateway LoadBalancer hostname: <lb-hostname>
```

## meshNetworks design

`01-istio-ambient.yaml` configures two networks:

| Network | Endpoints | Gateway |
|---|---|---|
| `main-network` | All cluster pods (`fromRegistry: rocks-cluster`) | EW gateway port **15443** (used by VM → cluster direction) |
| `vm-network` | VSI CIDR (`fromCidr: 10.243.64.0/24`) | None — cluster sidecars connect **directly** to the VM's registered IP |

- **C → A** (VSI → cluster): VM proxy routes through the EW gateway on port 15443 (`AUTO_PASSTHROUGH` SNI routing) because `ms-a` is on `main-network`.
- **B → C** (cluster → VSI): `ms-b`'s Envoy connects directly to the WorkloadEntry IP (`161.156.86.195:8080`) because `vm-network` has no gateway.

## Official Documentation

- [Installing Istio ambient mode (OSM 3.3)](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode)
- [Integrate Linux VMs into OpenShift Service Mesh](https://developers.redhat.com/articles/2026/04/17/integrate-red-hat-enterprise-linux-vms-openshift-service-mesh)
