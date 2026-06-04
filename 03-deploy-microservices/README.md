# Step 3 — Deploy ms-a and ms-b on ROCKS (Ambient)

## Summary

Deploys microservices **ms-a** and **ms-b** in project `osm-poc-demo` with OpenShift Routes, ServiceAccounts, ambient labels, and L4 `AuthorizationPolicy` rules enforcing **A→B→C→A** (C is onboarded in step 4). Includes structured logging via `TRACE_ID` / `X-Trace-Id` propagation.

## Prerequisites

- Steps [`01-setup`](../01-setup/) and [`02-ambient-mesh`](../02-ambient-mesh/) completed
- Images built and pushed (see [`microservices/`](../microservices/))
- Set image references before apply:

  ```bash
  export QUAY_ORG=your-quay-org
  export IMAGE_TAG=latest
  ```

- **Quay pull access on the cluster.** Local `podman pull` uses your `~/.docker/config.json` credentials; OpenShift nodes do not. If repositories are private, create a pull secret in `osm-poc-demo` and link it to the workload service accounts (Deployments use `serviceAccountName: ms-a` / `ms-b`, not `default`):

  ```bash
  # After podman login quay.io on your workstation:
  oc create secret generic quay-io-pull -n osm-poc-demo \
    --from-file=.dockerconfigjson="${HOME}/.docker/config.json" \
    --type=kubernetes.io/dockerconfigjson

  oc secrets link ms-a quay-io-pull --for=pull -n osm-poc-demo
  oc secrets link ms-b quay-io-pull --for=pull -n osm-poc-demo
  ```

  Alternatively, set each repository to **Public** in the Quay UI (acceptable for demos only). `ErrImagePull` / `unauthorized` from the kubelet always means the node cannot authenticate to the registry, not that the image is missing.

## Steps

1. Create project and mesh enrollment:

   ```bash
   cd 03-deploy-microservices
   oc apply -f 01-namespace.yaml
   ```

2. Deploy ms-a and ms-b:

   ```bash
   envsubst < 02-ms-a-deployment.yaml | oc apply -f -
   envsubst < 03-ms-b-deployment.yaml | oc apply -f -
   oc apply -f 04-services-routes.yaml
   ```

3. Register mesh service for external ms-c and apply policies:

   ```bash
   export VSI_PRIVATE_IP=<vsi-private-ip>
   ./apply-workload-c.sh
   oc apply -f 06-authorization-policies.yaml
   ```

   `apply-workload-c.sh` substitutes `VSI_PRIVATE_IP` into `05-workload-c.yaml` (WorkloadEntry with `network: vsi-network` + EndpointSlice with `serviceAccountName: ms-c`).

4. Wait for pods:

   ```bash
   oc -n osm-poc-demo rollout status deploy/ms-a
   oc -n osm-poc-demo rollout status deploy/ms-b
   oc -n osm-poc-demo get route,pod
   ```

5. Run an end-to-end chain (after VSI ms-c + ztunnel are up):

   ```bash
   TRACE=$(uuidgen | tr '[:upper:]' '[:lower:]')
   curl -s -H "X-Trace-Id: ${TRACE}" \
     "https://$(oc -n osm-poc-demo get route ms-a -o jsonpath='{.spec.host}')/api/run-chain"
   ```

6. Follow logs (same trace id on all three services):

   ```bash
   oc -n osm-poc-demo logs deploy/ms-a -f | grep "${TRACE}"
   oc -n osm-poc-demo logs deploy/ms-b -f | grep "${TRACE}"
   # On VSI: journalctl -u ms-c -f | grep "${TRACE}"
   ```

## Expected (Working) Output

Successful chain JSON from ms-a includes downstream responses from ms-b and ms-c. Logs show:

```text
[service=ms-a] [traceId=...] [action=CALL_B] ms-a is calling ms-b
[service=ms-b] [traceId=...] [action=FROM_A] ms-b received call from ms-a
[service=ms-b] [traceId=...] [action=CALL_C] ms-b is calling ms-c
[service=ms-c] [traceId=...] [action=FROM_B] ms-c received call from ms-b
[service=ms-c] [traceId=...] [action=CALL_A] ms-c is calling ms-a
[service=ms-a] [traceId=...] [action=FROM_C] ms-a received call from ms-c
```

## API Endpoints

| Service | Route / access | Endpoint | Description |
|---|---|---|---|
| ms-a | OpenShift Route `ms-a` | `GET /api/run-chain` | Starts A→B→C→A |
| ms-a | Route | `GET /api/call-b` | Calls B only |
| ms-b | Route `ms-b` | `GET /api/info` | Service metadata |
| ms-c | VSI `localhost:8080` | `GET /api/call-a` | Manual C→A test |

## Official Documentation

- [Deploying Bookinfo in ambient mode](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/installing/ossm-istio-ambient-mode)
- [AuthorizationPolicy](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/installing/ossm-authorization-policy)
- [Peer authentication / mTLS in ambient](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/installing/ossm-peer-authentication)
