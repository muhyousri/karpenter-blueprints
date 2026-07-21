# Karpenter Blueprint: ARC Zonal Shift

## Purpose

When an Availability Zone becomes impaired, the fastest path to recovery is moving away from it rather than diagnosing it. [Amazon Application Recovery Controller](https://aws.amazon.com/application-recovery-controller/) (ARC) provides exactly this: a mechanism to shift traffic and capacity decisions away from an impaired AZ, either manually or automatically.

This blueprint demonstrates how Karpenter v1.12+ natively integrates with ARC zonal shift, without requiring any external controller, custom resource, or additional infrastructure.

### What is ARC Zonal Shift?

ARC zonal shift is a capability within Amazon Application Recovery Controller that lets you temporarily move traffic and capacity decisions away from an impaired Availability Zone. There are two modes:

**Manual zonal shift**. You initiate the shift yourself when you detect an AZ issue (increased latency, intermittent errors, gray failures). You specify the AZ to shift away from and a duration (up to 3 days, extendable). This gives you immediate relief while you investigate the root cause.

**Zonal autoshift**. You authorize AWS to manage this on your behalf. ARC monitors for signals that indicate AZ health degradation and automatically shifts away from the affected zone. Zonal autoshift includes *practice runs* that periodically verify your cluster functions correctly with one less AZ, building confidence that a real shift won't cause secondary failures.

### Why does this matter for Karpenter?

Before this integration, ARC could shift load-balancer traffic and Auto Scaling Group provisioning away from an impaired AZ, but it had no way to communicate with Karpenter. This created a gap:

- ARC would cordon nodes and redirect traffic away from the impaired AZ
- But Karpenter would continue treating all AZs as equal, potentially launching new nodes *into* the impaired zone
- Karpenter's consolidation might disrupt nodes in healthy zones if it determined a cheaper configuration was available in the impaired zone
- Pods with flexible constraints could still end up scheduled on freshly launched nodes in the broken AZ

The result was a partially effective recovery. Traffic moved away, but compute capacity didn't follow the same logic.

### External controller approach

In February 2026, AWS published an [ARC Autoshift Karpenter Controller](https://github.com/aws-samples/sample-arc-autoshift-karpenter-controller) that bridges ARC and Karpenter. It works by:

1. An EventBridge rule watches for zonal autoshift events
2. An SQS queue stores the events
3. A controller pod polls the queue and mutates NodePool specs (removing the impaired zone from `topology.kubernetes.io/zone` requirements)

This approach requires deploying and maintaining additional infrastructure: EventBridge rules, SQS queues, IAM permissions, and a controller Deployment with at least two replicas for HA. It also modifies your NodePool specs directly, storing original values in annotations for later restoration.

### Native Karpenter integration

Starting with Karpenter v1.12, ARC zonal shift support is built directly into Karpenter. No external controller, CRD, EventBridge/SQS setup, or NodePool mutation is required. Karpenter integrates directly with the existing EKS cluster ARC resource and adjusts its scheduling logic internally.

You enable it with a single setting:

| Environment Variable | CLI Flag | Description |
| --- | --- | --- |
| `ENABLE_ZONAL_SHIFT` | `--enable-zonal-shift` | If true, enable zonal shift integration with ARC |

When a zonal shift is active, Karpenter changes its behavior in four specific ways:

1. **Stops provisioning in the impaired AZ**. No new nodes will be launched in that zone, regardless of what your NodePool's zone requirements say
2. **Halts voluntary disruptions for nodes in the impaired AZ**. Consolidation and drift won't terminate nodes that are already running there (to avoid cascading failures)
3. **Prevents voluntary disruptions in healthy zones if they depend on the impaired zone**. If consolidating a healthy-zone node would require rescheduling pods to the impaired zone, Karpenter blocks it
4. **Volume affinity pods don't trigger launch attempts**. Pods with strict EBS volume affinity that requires the impaired zone won't cause Karpenter to attempt (and fail) launches there

When the zonal shift expires or is canceled, Karpenter resumes normal operations automatically. No manual restoration step is needed.


## Requirements

* A Kubernetes cluster with **Karpenter v1.14.0+** installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* The `karpenter-crd` chart must be at v1.14.0+. If you upgraded Karpenter from an older version, ensure the CRDs are also updated. See [upgrade guide](https://karpenter.sh/docs/upgrading/upgrade-guide/#upgrading-to-1140).
* A `default` Karpenter `NodePool` as that's the one we'll use in this blueprint. You did this already in the ["Deploy a Karpenter Default EC2NodeClass and NodePool"](../../README.md) section from this repository.
* An EKS cluster running in a region with **at least 3 Availability Zones** (recommended for meaningful zonal shift testing).
* [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) configured with permissions to call `arc-zonal-shift` APIs.
* The Karpenter controller IAM role must have `arc-zonal-shift:GetManagedResource` permission. If you used the Terraform template in this repository, this permission is included.

**NOTE:**
* Zonal shift is not supported on EKS Auto Mode through this Karpenter setting. EKS Auto Mode has its own ARC integration managed by AWS. This blueprint covers OSS Karpenter only.
* The ARC Zonal Shift feature was introduced in Karpenter v1.12. v1.14 added improved logging for zonal shift events. This blueprint uses v1.14 for better observability.

## Enable Zonal Shift Support

Two steps are required: register your EKS cluster with ARC, then enable the setting on Karpenter.

### Register the EKS cluster with ARC

```sh
aws eks update-cluster-config \
  --name $CLUSTER_NAME \
  --zonal-shift-config enabled=true
```

### Enable zonal shift on Karpenter

Enable zonal shift on your existing Karpenter deployment:

```sh
kubectl -n karpenter set env deployment/karpenter ENABLE_ZONAL_SHIFT=true
```

Alternatively, if you manage Karpenter via Helm, include the setting in your Helm values:

```sh
helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace karpenter \
  --set "settings.enableZonalShift=true" \
  --reuse-values
```

Verify the setting is active:

```sh
kubectl -n karpenter get deployment karpenter -o jsonpath='{.spec.template.spec.containers[0].env}' | grep -i zonal
```

You should see `ENABLE_ZONAL_SHIFT` set to `true`.

## Deploy

Before applying the manifests, set your cluster-specific variables. If you're using the [Terraform template provided in this repo](../../cluster/terraform/), run the following commands:

```sh
export AWS_REGION="${AWS_REGION:-us-west-2}"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

Deploy the `NodePool` and `EC2NodeClass` used across all scenarios. The `nodepool.yaml` file contains both resources: a `NodePool` named `arc-zonal-shift` and an `EC2NodeClass` with the same name that configures the AMI, IAM role, security groups, and subnets:

```sh
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" nodepool.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" nodepool.yaml
kubectl apply -f nodepool.yaml
```

The key parts of the `NodePool` (simplified for readability, see `nodepool.yaml` for the full spec including limits, disruption policy, and expireAfter):

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: arc-zonal-shift
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
      taints:
        - key: intent
          value: arc-zonal-shift
          effect: NoSchedule
```

---

## Scenario 1: Manual Zonal Shift. Observe Karpenter Behavior

This scenario shows what happens when you trigger a manual zonal shift and Karpenter reacts by stopping provisioning in the impaired AZ and protecting nodes in healthy zones from disruptive consolidation.

### Deploy the workload

Deploy a stateless workload spread across all AZs:

```sh
kubectl apply -f workload.yaml
```

The workload uses `topologySpreadConstraints` with `whenUnsatisfiable: ScheduleAnyway` so pods distribute across zones but can consolidate into fewer zones during a shift:

```yaml
topologySpreadConstraints:
  - labelSelector:
      matchLabels:
        app: web-app-zonal
    maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
```

Wait for pods to be running across multiple AZs:

```sh
kubectl get pods -l app=web-app-zonal -o wide
kubectl get nodes -L topology.kubernetes.io/zone,karpenter.sh/nodepool -l karpenter.sh/nodepool=arc-zonal-shift
```

You should see nodes in at least 2-3 AZs. Note which AZs have nodes and pick one to shift away from.

### Trigger a manual zonal shift

Identify your cluster's AZs and choose one to shift away from. ARC requires the **Availability Zone ID** (e.g., `usw2-az3`), not the AZ name (e.g., `us-west-2c`). AZ IDs are consistent across accounts, while AZ names are account-specific mappings:

```sh
# Find AZ ID mapping for your region
aws ec2 describe-availability-zones --region $AWS_REGION \
  --query 'AvailabilityZones[*].[ZoneName,ZoneId]' --output table

# Pick an AZ that has nodes and use its Zone ID
export SHIFT_AZ_ID="usw2-az3"  # Replace with an AZ ID that has nodes
```

Start a manual zonal shift using the AWS CLI:

```sh
aws arc-zonal-shift start-zonal-shift \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME \
  --away-from $SHIFT_AZ_ID \
  --expires-in "30m" \
  --comment "Blueprint test: observe Karpenter behavior during zonal shift"
```

### Results

Watch Karpenter logs to see it react to the shift:

```sh
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --all-containers=true -f --tail=20
```

You should observe log messages indicating Karpenter is aware of the zonal shift and has excluded the impaired AZ from provisioning decisions.

**Verify no new nodes launch in the impaired AZ.** Scale up the workload to trigger new node provisioning:

```sh
kubectl scale deployment web-app-zonal --replicas=20
```

Check the new nodes. They should all be in healthy AZs:

```sh
kubectl get nodes -L topology.kubernetes.io/zone,karpenter.sh/nodepool -l karpenter.sh/nodepool=arc-zonal-shift
```

No new nodes should appear in the shifted AZ.

**Verify consolidation is blocked.** Even if the nodes in the impaired AZ become underutilized (because traffic is shifted away and pods are being rescheduled), Karpenter will not consolidate or terminate those nodes while the shift is active. Check for disruption-blocked events:

```sh
kubectl get events --field-selector reason=DisruptionBlocked
```

### Cancel the zonal shift

```sh
aws arc-zonal-shift list-zonal-shifts \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME

# Use the zonal-shift-id from the output above:
aws arc-zonal-shift cancel-zonal-shift \
  --zonal-shift-id <ZONAL_SHIFT_ID>
```

Once canceled, Karpenter resumes normal behavior. Nodes can be provisioned in all AZs again, and consolidation proceeds normally.

### Cleanup Scenario 1

```sh
kubectl scale deployment web-app-zonal --replicas=6
```

---

## Scenario 2: Zonal Autoshift. Fully Automated Recovery

This scenario enables zonal autoshift so that AWS automatically shifts away from an impaired AZ without manual intervention. Zonal autoshift includes practice runs that periodically verify your cluster can operate with one fewer AZ.

### Enable zonal autoshift on the EKS cluster

Zonal autoshift requires a **practice run configuration** before it can be enabled. Practice runs use a CloudWatch alarm to determine if your application remains healthy when an AZ is shifted away during a practice run.

First, create a CloudWatch alarm that ARC uses to verify your app stays healthy during practice runs:

```sh
aws cloudwatch put-metric-alarm \
  --alarm-name arc-zonal-shift-demo-alarm \
  --metric-name CPUUtilization \
  --namespace AWS/EKS \
  --statistic Average \
  --period 60 \
  --threshold 99 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 3 \
  --treat-missing-data notBreaching
```

Then create the practice run configuration referencing that alarm:

```sh
aws arc-zonal-shift create-practice-run-configuration \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME \
  --outcome-alarms type=CLOUDWATCH,alarmIdentifier=arn:aws:cloudwatch:$AWS_REGION:$ACCOUNT_ID:alarm:arc-zonal-shift-demo-alarm
```

Once the practice run configuration is in place, enable zonal autoshift:

```sh
aws arc-zonal-shift update-zonal-autoshift-configuration \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME \
  --zonal-autoshift-status ENABLED
```

Verify it's enabled:

```sh
aws arc-zonal-shift get-managed-resource \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME
```

### What happens during an autoshift

When ARC detects AZ degradation (based on internal health signals), it automatically initiates a zonal shift. Karpenter reacts identically to a manual shift:

1. Stops provisioning in the impaired AZ
2. Blocks voluntary disruptions (consolidation/drift) that interact with the impaired zone
3. When the autoshift completes, Karpenter resumes normal operations

The difference from Scenario 1 is that no human triggers the shift. ARC does it based on observed health signals.

### Practice runs

With zonal autoshift enabled, ARC periodically runs practice shifts to verify your workloads can tolerate losing one AZ. During a practice run:

- ARC shifts a portion of traffic away from one AZ
- Karpenter respects the shift and adjusts provisioning behavior
- If your workloads survive the practice run without issues, confidence increases
- If a practice run reveals problems (pods stuck pending, PDB violations), you'll discover it *before* a real incident

You can observe practice runs and autoshifts via CLI:

```sh
# List all active autoshifts in the region
aws arc-zonal-shift list-autoshifts --status ACTIVE

# Check your cluster's zonal autoshift status and practice run config
aws arc-zonal-shift get-managed-resource \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME

# List zonal shifts (includes practice runs) for your cluster
aws arc-zonal-shift list-zonal-shifts \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME
```

### Testing autoshift with AWS Fault Injection Service (FIS)

Instead of waiting for a real AZ impairment, you can use [AWS FIS](https://aws.amazon.com/fis/) to trigger a zonal autoshift. FIS provides an **AZ Availability: Power Interruption** scenario that pairs with the `aws:arc:start-zonal-autoshift` recovery action. Five minutes into the simulated power interruption, FIS triggers a zonal autoshift for your enabled resources, then cancels it when the experiment completes.

For setup instructions, see [Testing zonal autoshift with AWS FIS](https://docs.aws.amazon.com/r53recovery/latest/dg/testing-zonal-autoshift-fis.html).

**NOTE:** For a simpler test of Karpenter's zonal shift behavior without FIS, use a manual zonal shift as shown in Scenario 1. The Karpenter behavior is identical regardless of how the shift is triggered.

### Results

The expected behavior is identical to Scenario 1, but triggered automatically. Monitor the same signals:

```sh
# Watch for new zonal shifts
aws arc-zonal-shift list-zonal-shifts \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME

# Watch Karpenter logs for zonal shift awareness
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --all-containers=true -f --tail=20

# Verify no nodes are launched in the shifted AZ
kubectl get nodes -L topology.kubernetes.io/zone -l karpenter.sh/nodepool=arc-zonal-shift
```

### Cleanup Scenario 2

If you want to disable zonal autoshift after testing:

```sh
aws arc-zonal-shift update-zonal-autoshift-configuration \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME \
  --zonal-autoshift-status DISABLED
```

---

## Scenario 3: Scheduling Constraints and Stateful Workloads During a Zonal Shift

This scenario demonstrates workload configurations that allow pods to reschedule during a zonal shift, and configurations that prevent it.

Kubernetes `topologySpreadConstraints` control how pods are distributed across zones. The `whenUnsatisfiable` field determines what happens when the constraint cannot be met (e.g., when an AZ is removed by a zonal shift):

- `DoNotSchedule`: The scheduler will not place a pod if it would violate `maxSkew`. During a zonal shift, this means evicted pods from the impaired AZ cannot reschedule to healthy AZs because doing so would create an imbalanced spread.
- `ScheduleAnyway`: The scheduler places pods even if it violates `maxSkew`. During a zonal shift, evicted pods reschedule to healthy AZs immediately.

### Deploy both workload patterns

```sh
kubectl apply -f workload.yaml
kubectl apply -f workload-strict.yaml
```

Verify both are running and spread across AZs:

```sh
kubectl get pods -l app=web-app-zonal -o wide
kubectl get pods -l app=web-app-strict -o wide
```

### Trigger a zonal shift

Follow the same steps as Scenario 1 to start a manual zonal shift:

```sh
aws arc-zonal-shift start-zonal-shift \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME \
  --away-from $SHIFT_AZ_ID \
  --expires-in "15m" \
  --comment "Blueprint test: workload readiness"
```

### Observe the difference

While the zonal shift is active, scale both workloads up. Since Karpenter will not provision new nodes in the impaired AZ, new pods must schedule in healthy AZs only:

```sh
kubectl scale deployment web-app-zonal --replicas=12
kubectl scale deployment web-app-strict --replicas=12
```

The `ScheduleAnyway` workload (`web-app-zonal`) scales successfully. New pods schedule in healthy AZs even though the spread is uneven:

```sh
kubectl get pods -l app=web-app-zonal -o wide
```

The `DoNotSchedule` workload (`web-app-strict`) may have pods stuck in `Pending`. The scheduler cannot place them without violating `maxSkew` because no new capacity is available in the impaired AZ:

```sh
kubectl get pods -l app=web-app-strict --field-selector=status.phase=Pending
```

The YAML difference between them:

**DoNotSchedule (blocks scaling during a shift):**

```yaml
topologySpreadConstraints:
  - labelSelector:
      matchLabels:
        app: web-app-strict
    maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
```

**ScheduleAnyway (allows scaling during a shift):**

```yaml
topologySpreadConstraints:
  - labelSelector:
      matchLabels:
        app: web-app-zonal
    maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
  - labelSelector:
      matchLabels:
        app: web-app-zonal
    maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
```

### Stateful workloads: volume affinity considerations

Deploy a stateful workload with a zonal EBS volume:

```sh
kubectl apply -f workload-stateful.yaml
```

This workload uses a PersistentVolumeClaim backed by EBS. EBS volumes are zonal and exist in exactly one AZ. If that AZ is under a zonal shift:

- The pod **cannot** move to another AZ (its volume is physically in the impaired zone)
- Karpenter will **not** attempt to launch a node for this pod in the impaired AZ (it respects the shift)
- The pod remains `Pending` until the shift ends

This is a known limitation of ARC zonal shift with zonal storage like EBS. Pods bound to a persistent volume in the impaired AZ will remain unavailable until the shift ends. See the [EKS zonal shift documentation](https://docs.aws.amazon.com/eks/latest/userguide/zone-shift.html) for more details on stateful workload behavior during a zonal shift.

### Cancel the zonal shift and cleanup Scenario 3

```sh
aws arc-zonal-shift cancel-zonal-shift --zonal-shift-id <ZONAL_SHIFT_ID>
kubectl delete -f workload-strict.yaml
kubectl delete -f workload-stateful.yaml
kubectl delete -f workload.yaml
```

---

## Full Cleanup

```sh
kubectl delete -f .
```

Cancel any active zonal shifts:

```sh
aws arc-zonal-shift list-zonal-shifts \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME \
  --status ACTIVE

# For each active shift:
aws arc-zonal-shift cancel-zonal-shift --zonal-shift-id <ID>
```

Disable zonal autoshift if enabled:

```sh
aws arc-zonal-shift update-zonal-autoshift-configuration \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME \
  --zonal-autoshift-status DISABLED
```
