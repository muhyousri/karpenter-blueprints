# Karpenter Blueprint: CapacityBuffers

## Purpose

Karpenter provisions nodes just-in-time based on unscheduled pods. This is efficient, but it means pods wait for a node to launch and become `Ready` before they can start. [CapacityBuffers](https://karpenter.sh/docs/concepts/capacitybuffers/) let you pre-provision spare node capacity ahead of demand, so latency-sensitive workloads schedule instantly onto nodes that already exist.

A `CapacityBuffer` defines virtual placeholder pods that exist only in Karpenter's scheduling simulation. They are never created as real Kubernetes pods. There's no pod object to preempt, no scheduler overhead from evicting it, and no risk of it showing up in `kubectl get pods` and creating confusion. Karpenter provisions real, fully `Ready` nodes to fit these virtual pods. It re-verifies the buffer on every scheduling cycle and refills it automatically as real workloads consume the pre-provisioned capacity.

These are ordinary nodes from the Kubernetes scheduler's point of view once they exist. CapacityBuffers don't grant any scheduling exclusivity on their own. Any pod whose constraints are satisfied by that node can land on it. The section below on how CapacityBuffers connect to a NodePool explains what this means in practice and how to plan for it.

Before CapacityBuffers, pre-provisioning spare capacity in Karpenter meant approximating the same goal with a workaround. Teams ran a low-priority "dummy" Deployment sized to force the right instance shape, and relied on preemption to evict it when real pods landed. CapacityBuffers replace this natively. There's no preemption overhead and no manual instance-shape guesswork, since Karpenter runs the same scheduling simulation it already uses for real pods.

### How this compares to other capacity patterns in this repository

| | [`capacity-buffers`](.) (this blueprint) | [`node-reserved-headroom`](../node-reserved-headroom/) | [`static-nodepool`](../static-nodepool/) |
| --- | --- | --- | --- |
| **What's reserved** | Whole pre-warmed nodes, ahead of demand | A slice of capacity inside nodes already running real workloads | A fixed count of nodes |
| **Abstraction** | Pod-level. You describe pod requirements, Karpenter picks the node shape | Pod-level, via `PriorityClass` and resource requests | Node-level. You pick instance types and zones directly |
| **Cost optimization** | Stays in Karpenter's normal loop. Drift, expiry, and underutilized consolidation all still apply | Not applicable. Reserved capacity lives on nodes managed by their own NodePool | Excluded from consolidation entirely. Frozen until you scale it down |
| **Reversible** | Yes. Delete the `CapacityBuffer` object at any time | Yes. Scale the DaemonSet or remove the `PriorityClass` | No. Once `replicas` is set on a NodePool, it can't be unset |
| **Best for** | Reducing scheduling latency for bursty or predictable demand on new capacity | Instant burst access to capacity co-located with steady-state workloads | Guaranteed node count for budgeting, ODCRs, Capacity Blocks, or infrastructure boundaries |

If you're unsure which pattern to use, reach for `capacity-buffers` by default for anything latency-sensitive and workload-shaped. Reach for `node-reserved-headroom` if you already have steady-state workloads and want instant same-node burst access. Reach for `static-nodepool` only when you need a truly fixed node count that Karpenter will never touch for cost reasons, for example when you've purchased ODCRs or Capacity Blocks.

## Requirements

* A Kubernetes cluster with Karpenter v1.14.0+ installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* The `karpenter-crd` chart must be at v1.14.0+. The `CapacityBuffer` CRD ships there, not in the main `karpenter` chart.
* A `default` Karpenter `EC2NodeClass` and `NodePool`, plus the additional `NodePool`/`EC2NodeClass` manifests included in this blueprint.

**NOTE:** CapacityBuffers are currently in alpha (`autoscaling.x-k8s.io/v1beta1`) and the API may change in future versions.

## Enable CapacityBuffer Feature Gate

CapacityBuffers require enabling the `CapacityBuffer` feature gate in Karpenter. Update your Karpenter deployment to include the feature gate:

```sh
helm registry logout public.ecr.aws
helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace karpenter \
  --set "settings.featureGates.capacityBuffer=true" \
  --reuse-values
```

Alternatively, if you're using the Terraform template from this repository, you can add the feature gate to the Karpenter Helm values.

Verify the feature gate is enabled by checking the Karpenter deployment configuration:

```sh
kubectl -n karpenter get deployment karpenter -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="FEATURE_GATES")].value}'
```

You should see `CapacityBuffer=true` in the output.

## Deploy

Deploy the shared `NodePool` used across Scenarios 1, 2, and 4:

```sh
kubectl apply -f nodepool.yaml
```

This creates a `NodePool` named `capacity-buffer`, tainted so only pods that tolerate `intent=capacity-buffer` land there. It reuses the cluster's `default` `EC2NodeClass` (one of this blueprint's requirements), since nothing about these scenarios needs a different AMI or networking setup:

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: capacity-buffer
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        name: default
        kind: EC2NodeClass
      taints:
        - key: intent
          value: capacity-buffer
          effect: NoSchedule
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
```

Scenario 3 (GPU) is the exception. It uses its own dedicated `NodePool`/`EC2NodeClass` (`gpu-nodepool.yaml`) because it needs a different AMI, and it's deployed separately within that scenario's steps below.

## How CapacityBuffers Connect to a NodePool

Each scenario below applies two new objects on top of the `NodePool` you already deployed. Before going further, it helps to know what each one does and how they relate to each other.

[`PodTemplate`](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-template-v1/) is a standard Kubernetes object, not something new introduced by Karpenter. It stores a pod spec as a reusable stencil, and it's easy to misread it as a way to provision real pods. It isn't. Applying a `PodTemplate` does not create any real pods. It only exists to be referenced. Karpenter's buffer controller reads it to construct virtual pods for its scheduling simulation, the same virtual pods described in the Purpose section above. Think of it as telling Karpenter "here's the shape of node I want warm," not "here's a workload to run."

`CapacityBuffer` is the new CRD this blueprint depends on (`autoscaling.x-k8s.io/v1beta1`). It references a `PodTemplate` through `podTemplateRef`, or an existing Deployment, StatefulSet, or ReplicaSet through `scalableRef`, and says how many virtual chunks of that shape to keep as spare capacity, using `replicas`, `percentage`, or `limits`.

Neither object references a `NodePool` directly. There's no field on a `CapacityBuffer` that names one. The connection works exactly like scheduling a real pod. Karpenter compares the `PodTemplate`'s `nodeSelector`, tolerations, affinity, and resource requests against your `NodePool`'s requirements during its normal scheduling simulation. Whichever `NodePool` would host a real pod with that same spec is the `NodePool` that ends up hosting the buffer's nodes. If you have multiple `NodePool`s, buffer chunks flow through the same selection logic as any other pod, including `NodePool` weight.

This has a direct design consequence. Because matching is pod-level, nothing stops other real pods from landing on a pre-warmed node if they also satisfy that `NodePool`'s requirements and there's room left. That's how the buffer's capacity is meant to get consumed. But it also means an unrelated pod can consume it first if your constraints are too loose. The tighter and more specific your `NodePool` requirements and taints, and your `PodTemplate`'s matching tolerations, the more reliably the buffer serves the workload you actually intend it for. Planning your requirements and constraints carefully matters more here than with a typical NodePool, since the whole point of a buffer is for something to eventually land on it, you just want to control what that something is. This blueprint's manifests apply a dedicated taint and toleration for exactly this reason, see `nodepool.yaml` and `podtemplate.yaml`.

---

## Scenario 1: Fixed-size buffer

Let's suppose you have this now: a small app called `web-app`, already running with 2 replicas on the `NodePool` you just deployed. It sees bursty traffic, and when a burst hits, you want new replicas to come up as fast as possible instead of waiting on a fresh node to launch.

Deploy `web-app` so you have that starting point:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
spec:
  replicas: 2
  ...
```

```sh
kubectl apply -f workload.yaml
kubectl get pods -l app=web-app
```

Nothing about `web-app` needs to change for the rest of this scenario. A `CapacityBuffer` gets added alongside it, not instead of it.

Now add the buffer. A `PodTemplate` describes the shape of one buffer "chunk", matching `web-app`'s own resource requests so the pre-warmed capacity is actually useful to it:

```yaml
apiVersion: v1
kind: PodTemplate
metadata:
  name: web-buffer-template
template:
  spec:
    containers:
      - name: placeholder
        resources:
          requests:
            cpu: "1"
            memory: "1Gi"
    nodeSelector:
      intent: capacity-buffer
    tolerations:
      - key: intent
        value: capacity-buffer
        effect: NoSchedule
```

A `CapacityBuffer` then requests 3 chunks of that shape:

```yaml
apiVersion: autoscaling.x-k8s.io/v1beta1
kind: CapacityBuffer
metadata:
  name: web-app-buffer
spec:
  provisioningStrategy: "buffer.x-k8s.io/active-capacity"
  podTemplateRef:
    name: web-buffer-template
  replicas: 3
```

```sh
kubectl apply -f podtemplate.yaml
kubectl apply -f capacity-buffer-fixed.yaml
```

That's the entire difference in the architecture. `web-app` is untouched, and two new objects sit next to it.

### Results

Wait about a minute, then check the buffer status:

```sh
kubectl get capacitybuffer web-app-buffer -o wide
```

You should see `Provisioning: True` once virtual pods fit on existing capacity. Depending on whether `web-app`'s current nodes already have room, Karpenter either reuses that slack or provisions new nodes to satisfy the 3 requested chunks:

```sh
kubectl get nodeclaims -l intent=capacity-buffer
```

The `PodTemplate` in this example requests 1 CPU and 1Gi per chunk. That's small enough that multiple chunks can bin-pack onto a single node, the same way Karpenter would bin-pack real pods with identical requests. Buffer chunks aren't guaranteed one node per chunk. If you need spare capacity spread across multiple nodes, size the `PodTemplate` requests closer to a full node, or add a `podAntiAffinity` rule to the template the same way you would for real pods, so Karpenter provisions separate nodes per chunk.

Check the pod count for `web-app` again:

```sh
kubectl get pods -l app=web-app
```

Still 2 pods. Adding the buffer never changed `web-app`'s pod count, because buffer chunks are virtual. They never become real `web-app` pods on their own. Karpenter provisions real, `Ready` capacity to fit them, but nothing runs there until a real pod, whether from `web-app` or something else, actually schedules onto it.

Despite that spare capacity having no real pods, the node hosting it survives empty consolidation. Confirm this by checking events:

```sh
kubectl get events --field-selector reason=Unconsolidatable
```

You should see a message like `Node has buffer pods`. Karpenter's Balanced and `WhenEmptyOrUnderutilized` consolidation policies both explicitly skip empty-consolidation for buffer-backed nodes. See the [disruption integration in the Karpenter docs](https://karpenter.sh/docs/concepts/capacitybuffers/#integration-with-disruption) for details.

Now simulate that burst of traffic by scaling `web-app` up:

```sh
kubectl scale deployment web-app --replicas=5
```

```sh
kubectl get pods -l app=web-app -w
```

The new pods should reach `Running` within seconds, since they land on capacity that was already `Ready` before you scaled the Deployment.

Drift and expiry still apply to buffer-backed nodes. If you replace the `EC2NodeClass` AMI or the node expires, Karpenter disrupts the node as normal. The buffer self-heals by re-provisioning a replacement node to keep the virtual pods satisfied.

### Cleanup Scenario 1

```sh
kubectl delete -f capacity-buffer-fixed.yaml
kubectl delete -f podtemplate.yaml
kubectl delete -f workload.yaml
```

---

## Scenario 2: Buffer that tracks a Deployment's size

Let's suppose your team runs `api-service`, a workload that scales up and down a lot depending on load, and a flat buffer size doesn't make sense for it. When it has 5 replicas, keeping 3 pre-warmed chunks around is wasteful. When it scales to 50, 3 chunks aren't enough. You want the buffer to scale with the workload itself.

Deploy `api-service` and a `CapacityBuffer` using `scalableRef` and `percentage` to maintain 20% of its current replica count as spare capacity:

```yaml
apiVersion: autoscaling.x-k8s.io/v1beta1
kind: CapacityBuffer
metadata:
  name: api-service-buffer
spec:
  provisioningStrategy: "buffer.x-k8s.io/active-capacity"
  scalableRef:
    apiGroup: apps
    kind: Deployment
    name: api-service
  percentage: 20
```

```sh
kubectl apply -f workload-scalable.yaml
kubectl apply -f capacity-buffer-scalable.yaml
```

### Results

`api-service` starts with 5 replicas, so the buffer maintains `roundup(5 * 0.20) = 1` chunk:

```sh
kubectl get capacitybuffer api-service-buffer -o jsonpath='{.status.replicas}'
```

Scale the Deployment up:

```sh
kubectl scale deployment api-service --replicas=20
```

Within about 30 seconds, the buffer controller's polling interval per the [Karpenter docs](https://karpenter.sh/docs/concepts/capacitybuffers/#limitations-and-considerations), the buffer recalculates to `roundup(20 * 0.20) = 4` chunks:

```sh
kubectl get capacitybuffer api-service-buffer -w
```

Karpenter provisions additional nodes to match. Neither `static-nodepool` nor `node-reserved-headroom` has an equivalent. Both require you to manually resize capacity as workload demand changes.

### Cleanup Scenario 2

```sh
kubectl delete -f capacity-buffer-scalable.yaml
kubectl delete -f workload-scalable.yaml
```

---

## Scenario 3: Pre-warming GPU capacity

Let's suppose you run a GPU inference service, and it needs to scale out as soon as demand shows up. The problem is that GPU nodes report `Ready` well before they're actually usable. The NVIDIA driver has to install, and the device plugin has to start and register `nvidia.com/gpu` as an allocatable resource. That process commonly takes several minutes on top of instance launch. For a service that scales out on demand, that latency lands directly in the critical path.

A GPU `CapacityBuffer` front-loads all of it. The node launches, drivers install, and the device plugin finishes registering the GPU before any real pod needs it.

This blueprint uses [Bottlerocket](https://karpenter.sh/docs/concepts/nodeclasses/#specamifamily), which ships the NVIDIA driver and device plugin pre-installed on its accelerated AMI variant. Karpenter's `bottlerocket` alias automatically resolves to the correct GPU-enabled variant for GPU instance types, so the `EC2NodeClass` needs no extra configuration beyond the alias itself.

The goal of this scenario isn't to demonstrate a specific instance type. It's to show that once a GPU node is `Ready`, scale-out is near-instant regardless of which instance you land on. So the `NodePool` allows both spot and on-demand, and stays open across the entire `g` and `p` instance categories rather than pinning specific instance types, to maximize the odds of getting capacity quickly rather than waiting on one specific type:

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-capacity-buffer
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand", "spot"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["g", "p"]
        - key: karpenter.k8s.aws/instance-gpu-manufacturer
          operator: In
          values: ["nvidia"]
      taints:
        - key: nvidia.com/gpu
          effect: NoSchedule
```

This scenario also demonstrates capping the buffer with `spec.limits`, so a GPU buffer doesn't hold unbounded warm capacity you're paying for:

```yaml
apiVersion: autoscaling.x-k8s.io/v1beta1
kind: CapacityBuffer
metadata:
  name: gpu-inference-buffer
spec:
  provisioningStrategy: "buffer.x-k8s.io/active-capacity"
  podTemplateRef:
    name: gpu-buffer-template
  limits:
    nvidia.com/gpu: "2"
```

Unlike the shared `NodePool`, `gpu-nodepool.yaml` ships its own `EC2NodeClass`, so it needs your cluster-specific values. If you're using the Terraform template provided in this repo, run the following commands:

```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> ***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). Karpenter auto-generates the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles) in your `EC2NodeClass` given the role that you specify in [spec.role](https://karpenter.sh/docs/concepts/nodeclasses/) with the placeholder `KARPENTER_NODE_IAM_ROLE_NAME`, which is a way to pass a single IAM role to the EC2 instance launched by the Karpenter `NodePool`. Typically, the instance profile name is the same as the IAM role (not the ARN).

Deploy the GPU `NodePool`, `PodTemplate`, and buffer:

```sh
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" gpu-nodepool.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" gpu-nodepool.yaml
kubectl apply -f gpu-nodepool.yaml
kubectl apply -f gpu-podtemplate.yaml
kubectl apply -f capacity-buffer-gpu.yaml
```

The buffer requests as many chunks as fit within `limits: {nvidia.com/gpu: "2"}`, capping the buffer at 2 warm GPUs regardless of how large you configure the `NodePool` to scale.

<details>
<summary>Why <code>gpu-podtemplate.yaml</code> sets <code>requests.nvidia.com/gpu</code> explicitly</summary>

Real pods get `requests.nvidia.com/gpu` auto-defaulted from `limits` by API server admission. Buffer virtual pods never go through admission, so that defaulting never happens. Without an explicit `requests.nvidia.com/gpu`, the buffer sees zero GPU demand and `spec.limits` can't calculate a chunk count. Always set it explicitly on a `PodTemplate` used for buffers.
</details>

<details>
<summary>What pre-warming doesn't cover, and how to close the gap</summary>

Buffer virtual pods never reach kubelet, so a buffer only pre-warms node-level things (OS, drivers, device plugins). It doesn't pull your container image or download model weights, which are often the bigger share of GPU cold-start latency, and closing that gap on the same `EC2NodeClass` depends on your workload (image size, model size, how often either changes). See the [AI on EKS container startup guide](https://awslabs.github.io/ai-on-eks/docs/guidance/container-startup-time) for the available strategies and their trade-offs.
</details>

### Results

Wait for the GPU node (this can take a few minutes):

```sh
kubectl get nodeclaims -l intent=gpu-capacity-buffer -w
```

Once the node is `Ready`, confirm the device plugin has finished registering the GPU, not just that the node exists:

```sh
kubectl get nodes -l intent=gpu-capacity-buffer -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'
```

You should see `1` (or more), proving the full driver and device-plugin cycle already completed on an idle node.

Deploy the real GPU workload:

```sh
kubectl apply -f workload-gpu.yaml
```

```sh
kubectl logs pod/gpu-inference
```

The pod should reach `Running` and print GPU details within seconds. It landed on a node whose GPU stack was already warm, instead of waiting through the full driver and device-plugin cycle a cold GPU node would require. Note which instance type and capacity type Karpenter actually chose, since with both spot and on-demand in play across the whole `g` and `p` categories, it may not be the same one twice:

```sh
kubectl get nodeclaims -l intent=gpu-capacity-buffer -o custom-columns="NODE:.status.nodeName,TYPE:.status.capacity.nvidia\.com/gpu,CAPACITY:.spec.requirements"
```

### Cleanup Scenario 3

```sh
kubectl delete -f workload-gpu.yaml
kubectl delete -f capacity-buffer-gpu.yaml
kubectl delete -f gpu-podtemplate.yaml
kubectl delete -f gpu-nodepool.yaml
```

---

## Scenario 4: Forecast-driven buffers (building block for predictive scalers)

Let's suppose an external predictive scaler forecasts that a workload will need N additional replicas in the next few minutes. Instead of waiting for that demand to actually arrive and then scaling, it wants to pre-provision capacity for the forecast ahead of time.

This isn't a specific integration with any autoscaler. It demonstrates the primitive a predictive scaler would need to drive this pattern. A controller that knows a future replica count patches a `CapacityBuffer`'s `spec.replicas` ahead of time, and Karpenter pre-provisions the nodes. When the forecast materializes and the real workload is scaled, pods land on capacity that's already warm.

The `scalableRef` and `percentage` mechanism from Scenario 2 doesn't fit this use case. It only tracks a workload's current replica count on a 30-second poll and has no forecast input. A forecast-driven buffer must be driven directly through `podTemplateRef` and `replicas`, set by whatever component owns the forecast:

```yaml
apiVersion: autoscaling.x-k8s.io/v1beta1
kind: CapacityBuffer
metadata:
  name: forecast-driven-buffer
spec:
  provisioningStrategy: "buffer.x-k8s.io/active-capacity"
  podTemplateRef:
    name: web-buffer-template
  replicas: 0
```

Deploy the buffer, starting at 0 replicas:

```sh
kubectl apply -f capacity-buffer-forecast.yaml
```

`forecast-predictor.sh` stands in for the predictive scaler. Internally, it runs a `kubectl patch` against the buffer's `spec.replicas` to the forecast value, then waits to simulate the forecast lead time. The arguments below tell it to patch the `forecast-driven-buffer` `CapacityBuffer` to 5 replicas, then wait 90 seconds before returning, simulating a forecast made 90 seconds ahead of the real demand:

```sh
./forecast-predictor.sh forecast-driven-buffer 5 90
```

### Results

While the script waits, check that Karpenter is already provisioning nodes for the forecast, before any real pod exists:

```sh
kubectl get capacitybuffer forecast-driven-buffer -w
kubectl get nodeclaims -l intent=capacity-buffer
```

As in Scenario 1, small chunk requests bin-pack onto as few nodes as needed, so a forecast of 5 replicas may show up as 1-2 nodes rather than 5. What matters for this scenario is that nodes appear before the real Deployment is scaled, not the exact count.

Once the script's simulated lead time elapses, scale the real workload to the forecasted count, as a real predictive scaler would once the actual event arrives:

```sh
kubectl apply -f workload-forecast.yaml
kubectl scale deployment web-app-forecast --replicas=5
```

```sh
kubectl get pods -l app=web-app-forecast -w
```

Pods reach `Running` immediately, since the nodes were provisioned during the simulated forecast window rather than after the scale-out request.

### Cleanup Scenario 4

```sh
kubectl delete -f workload-forecast.yaml
kubectl delete -f capacity-buffer-forecast.yaml
```

---

## Key Takeaways

1. CapacityBuffers pre-provision real, `Ready` nodes ahead of demand, without real placeholder pods. There's no preemption overhead and no dummy Deployment to manage.
2. A buffer-backed node can look empty and still be protected from consolidation. `kubectl get pods` shows nothing, but the virtual buffer pods block empty-consolidation.
3. Nothing stops other pods from landing on a pre-warmed node besides the ones you intended. Plan your `NodePool` requirements, taints, and `PodTemplate` tolerations as carefully as you would for any dedicated workload, since matching is pod-level, not buffer-level.
4. Drift and expiry still apply. Buffers aren't exempt from cost or lifecycle disruption. They self-heal by re-provisioning to keep the buffer satisfied.
5. `scalableRef` and `percentage` track current workload size, not a forecast. For predictive or forecast-driven pre-provisioning, drive `replicas` directly through `podTemplateRef`.
6. Cap GPU (or any expensive) buffers with `spec.limits`. Otherwise a buffer can hold indefinitely warm, indefinitely billed capacity.
7. A buffer only pre-warms what's node-level: the OS, drivers, and device plugins. Image pulls and model weights are workload-level and only happen once a real pod lands. Close that gap on the same `EC2NodeClass`, choosing a strategy for your workload from the [AI on EKS container startup guide](https://awslabs.github.io/ai-on-eks/docs/guidance/container-startup-time).
8. This is alpha and not supported on EKS Auto Mode. Treat it as a pattern to evaluate, not yet a default for production, without validating your alpha-API risk tolerance.

## Full Cleanup

```sh
kubectl delete -f . --ignore-not-found=true
```
