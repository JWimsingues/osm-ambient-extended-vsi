# Step 1 — Prerequisites and Sail Operator

## Description

This step prepares a ROCKS (OpenShift on IBM Cloud) cluster for OpenShift Service Mesh (OSM) 3.2 in Istio ambient mode. It installs the Sail Operator from OperatorHub and creates the namespaces required for `Istio`, `IstioCNI`, and `ZTunnel`.

## Prerequisites

- OpenShift 4.19+ (ROCKS) with OVN-Kubernetes CNI
- `routingViaHost: true` in the OVN-Kubernetes configuration (required for ambient mode)
- Cluster-admin access (`oc login`)
- `oc` CLI and `istioctl` (matching your OSM version)
- Network connectivity between the cluster and the IBM Cloud VSI (for step 4)

## Steps

1. Clone this repository and enter this folder:

   ```bash
   cd 01-setup
   ```

2. Verify OVN-Kubernetes routing (cluster-admin):

   ```bash
   oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}'; echo
   ```

   Expected: `true`. If not, follow [Configuring OVN-Kubernetes for ambient mode](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/installing/ossm-istio-ambient-mode).

   If the command prints **false**, apply this remediation:

   ```bash
   oc patch networks.operator.openshift.io cluster --type=merge -p \
     '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost": true}}}}}'
   oc get clusteroperator network -w
   oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node
   oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}'; echo
   ```

3. Install the Red Hat OpenShift Service Mesh / Sail Operator:

   ```bash
   oc apply -f 01-operator-subscription.yaml
   oc wait --for=condition=Available subscription/redhat-openshift-service-mesh -n openshift-operators --timeout=600s
   ```

4. Create mesh infrastructure namespaces (labeled `istio-discovery=enabled` for istiod discovery in step 2):

   ```bash
   oc apply -f 02-namespaces.yaml
   ```

## Expected Output

```text
subscription.operators.coreos.com/redhat-openshift-service-mesh created
namespace/istio-system created
namespace/istio-cni created
namespace/ztunnel created
```

## Official Documentation

- [Installing OpenShift Service Mesh 3.2](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/installing/index)
- [Istio ambient mode (OSM 3.2)](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/installing/ossm-istio-ambient-mode)
