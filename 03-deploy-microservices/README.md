# Step 3 — Deploy ms-a and ms-b on ROCKS

## Summary

Deploys microservices **ms-a** and **ms-b** in project `osm-poc-demo` with OpenShift Routes, ServiceAccounts, Envoy sidecar injection, and L4 `AuthorizationPolicy` rules enforcing **A→B→C→A**. Also registers the mesh resources for the VSI-hosted `ms-c` (step 4 starts the actual process on the VM).

## Prerequisites

- Steps [`01-setup`](../01-setup/) and [`02-ambient-mesh`](../02-ambient-mesh/) completed
- Images built and pushed to Quay (see [`microservices/`](../microservices/))
- **Quay pull access on the cluster.** If your repositories are private, create a pull secret:

  ```bash
  oc create secret generic quay-io-pull -n osm-poc-demo \
    --from-file=.dockerconfigjson="${HOME}/.docker/config.json" \
    --type=kubernetes.io/dockerconfigjson
  oc secrets link ms-a quay-io-pull --for=pull -n osm-poc-demo
  oc secrets link ms-b quay-io-pull --for=pull -n osm-poc-demo
  ```

  Alternatively, set each `osm-poc-ms-*` repository to **Public** in the Quay UI (acceptable for demos).

## Steps

1. Create project and mesh enrollment:

   ```bash
   cd 03-deploy-microservices
   oc apply -f 01-namespace.yaml
   ```

2. Deploy ms-a and ms-b:

   ```bash
   oc apply -f 02-ms-a-deployment.yaml
   oc apply -f 03-ms-b-deployment.yaml
   oc apply -f 04-services-routes.yaml
   ```

   Both deployments use `sidecar.istio.io/inject: "true"` and `ambient.istio.io/redirection: disabled` so they run with Envoy sidecars (not ambient ztunnel). This is required for cross-network routing with the VM proxy.

3. Register mesh resources for ms-c and apply authorization policies:

   ```bash
   oc apply -f 05-workload-c.yaml
   oc apply -f 06-authorization-policies.yaml
   ```

   `05-workload-c.yaml` creates:
   - `ServiceAccount/ms-c` — mesh identity for the VSI workload
   - `WorkloadGroup/ms-c` — template for auto-registration when the VM sidecar connects
   - `Service/ms-c` — ClusterIP so cluster workloads can resolve `ms-c` by DNS
   - `ServiceEntry/ms-c` — binds the ClusterIP service to the auto-registered WorkloadEntry

   The VM's IP is **not** specified here; istiod auto-creates a `WorkloadEntry` using the `INSTANCE_IP` from the VM's `cluster.env` when the VM sidecar connects.

4. Wait for pods to become ready:

   ```bash
   oc -n osm-poc-demo rollout status deploy/ms-a
   oc -n osm-poc-demo rollout status deploy/ms-b
   oc -n osm-poc-demo get pod,route
   ```

   Each pod should show `2/2 Running` (app container + `istio-proxy` sidecar).

5. Run the full chain (once VSI ms-c is running — step 4):

   ```bash
   MS_A_URL="https://$(oc -n osm-poc-demo get route ms-a -o jsonpath='{.spec.host}')"
   TRACE=$(uuidgen | tr '[:upper:]' '[:lower:]')
   curl -sk -H "X-Trace-Id: ${TRACE}" "${MS_A_URL}/api/run-chain"
   ```

6. Follow logs (same `traceId` across all three services):

   ```bash
   oc -n osm-poc-demo logs deploy/ms-a -c ms-a --since=2m | grep "${TRACE}"
   oc -n osm-poc-demo logs deploy/ms-b -c ms-b --since=2m | grep "${TRACE}"
   # On VSI:
   # sudo grep "${TRACE}" /var/log/osm-poc/ms-c.log
   ```

## Expected Output

Successful chain JSON from ms-a includes downstream responses from ms-b and ms-c:

```text
[service=ms-a] [traceId=...] [action=CALL_B]  ms-a is calling ms-b
[service=ms-b] [traceId=...] [action=FROM_A]  ms-b received call from ms-a
[service=ms-b] [traceId=...] [action=CALL_C]  ms-b is calling ms-c
[service=ms-c] [traceId=...] [action=FROM_B]  ms-c received call from ms-b
[service=ms-c] [traceId=...] [action=CALL_A]  ms-c is calling ms-a
[service=ms-a] [traceId=...] [action=FROM_C]  ms-a received call from ms-c
```

## API Endpoints

| Service | Access | Endpoint | Description |
|---|---|---|---|
| ms-a | OpenShift Route | `GET /api/run-chain` | Starts A→B→C→A |
| ms-a | OpenShift Route | `GET /api/call-b` | Calls B only |
| ms-a | OpenShift Route | `GET /health` | Liveness |
| ms-b | OpenShift Route | `GET /api/info` | Service metadata |
| ms-c | VSI `localhost:8080` | `GET /api/call-a` | Manual C→A test |

## Official Documentation

- [Deploying workloads in ambient mode (OSM 3.3)](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode)
- [AuthorizationPolicy (OSM 3.3)](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-authorization-policy)
