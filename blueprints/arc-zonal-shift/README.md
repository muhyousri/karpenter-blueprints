# Karpenter Blueprint: ARC Zonal Shift

## Purpose

When an Availability Zone becomes impaired, you want Karpenter to stop launching nodes there and protect existing workloads from unnecessary disruption. By enabling [ARC zonal shift](https://aws.amazon.com/application-recovery-controller/) on your EKS cluster, Karpenter automatically adjusts its provisioning and disruption behavior when a shift is active, whether triggered manually or automatically via zonal autoshift. This blueprint shows how to enable the integration, trigger a manual zonal shift, observe how different workload configurations (flexible topology constraints, strict constraints, and stateful EBS volumes) respond during an AZ impairment, and how to enable zonal autoshift for automated recovery.

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

### Karpenter behavior during a zonal shift

Starting with Karpenter v1.12, ARC zonal shift support is built directly into Karpenter. No external controller, CRD, EventBridge/SQS setup, or NodePool mutation is required. Karpenter integrates directly with the existing EKS cluster ARC resource and adjusts its scheduling logic internally.

You enable it with a single setting:

| Environment Variable | CLI Flag | Description |
| --- | --- | --- |
| `ENABLE_ZONAL_SHIFT` | `--enable-zonal-shift` | If true, enable zonal shift integration with ARC |

The Karpenter controller role also requires `arc-zonal-shift:GetManagedResource` permission.

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
  --zonal-shift-config enabled=true || true
```

You might see the following error if the cluster is already registered with ARC. You don't need to worry about this error, it means zonal shift is already enabled:

```
InvalidParameterException: No changes needed for the ZonalShiftConfig provided.
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

Set your environment variables:

```sh
export AWS_REGION="${AWS_REGION:-us-west-2}"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
```

Deploy the NodePool and all three workloads:

```sh
kubectl apply -f nodepool.yaml
kubectl apply -f workload.yaml
kubectl apply -f workload-strict.yaml
kubectl apply -f workload-stateful.yaml
```

- `workload.yaml`: Uses `topologySpreadConstraints` with `whenUnsatisfiable: ScheduleAnyway` (flexible, can tolerate AZ loss)
- `workload-strict.yaml`: Uses `whenUnsatisfiable: DoNotSchedule` (strict, cannot violate maxSkew)
- `workload-stateful.yaml`: Uses a PersistentVolumeClaim backed by EBS (zonal storage, physically pinned to one AZ)

Verify all pods are running and spread across AZs:

```sh
kubectl get pods -l app=web-app-zonal -o wide
kubectl get pods -l app=web-app-strict -o wide
kubectl get pods -l app=web-app-stateful -o wide
kubectl get nodes -L topology.kubernetes.io/zone,karpenter.sh/nodepool -l karpenter.sh/nodepool=arc-zonal-shift
```

## Results

### Trigger a manual zonal shift

```sh
export SHIFT_AZ=$(kubectl get pod -l app=web-app-stateful -o jsonpath='{.items[0].spec.nodeName}' | \
  xargs kubectl get node -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
export SHIFT_AZ_ID=$(aws ec2 describe-availability-zones --region $AWS_REGION \
  --filters "Name=zone-name,Values=$SHIFT_AZ" \
  --query 'AvailabilityZones[0].ZoneId' --output text)

aws arc-zonal-shift start-zonal-shift \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME \
  --away-from $SHIFT_AZ_ID \
  --expires-in "30m" \
  --comment "Blueprint test: observe Karpenter behavior during zonal shift"
```

Watch Karpenter logs to see it react:

```sh
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --all-containers=true -f --tail=20
```

### Flexible workload scales into healthy AZs

Scale up the `ScheduleAnyway` workload during the active shift:

```sh
kubectl scale deployment web-app-zonal --replicas=12
kubectl get pods -l app=web-app-zonal -o wide
```

New pods schedule in healthy AZs only. Karpenter provisions new nodes exclusively in AZs that are not under the shift. Check that no new nodes appear in the impaired AZ:

```sh
kubectl get nodes -L topology.kubernetes.io/zone -l karpenter.sh/nodepool=arc-zonal-shift
```

### Strict workload cannot scale

Scale up the `DoNotSchedule` workload during the same shift:

```sh
kubectl scale deployment web-app-strict --replicas=12
kubectl get pods -l app=web-app-strict --field-selector=status.phase=Pending
```

Some pods are stuck in `Pending`. The scheduler cannot place them without violating `maxSkew` because no new capacity is available in the impaired AZ. This is the `DoNotSchedule` constraint blocking recovery.

The difference is the `whenUnsatisfiable` field:

```yaml
# Flexible (workload.yaml) - allows uneven spread during a shift
whenUnsatisfiable: ScheduleAnyway

# Strict (workload-strict.yaml) - blocks scheduling if spread is violated
whenUnsatisfiable: DoNotSchedule
```

### Stateful workload remains unavailable

The stateful workload's pod is bound to an EBS volume in one AZ. During a zonal shift, Karpenter protects nodes in the impaired AZ from disruption, so the stateful pod keeps running. To simulate a pod loss due to an AZ impairment, delete the pod:

```sh
kubectl delete pod -l app=web-app-stateful
kubectl get pods -l app=web-app-stateful
```

The replacement pod stays `Pending` because its volume is physically in the impaired AZ and Karpenter will not launch a node there. This is a known limitation of ARC zonal shift with zonal storage like EBS. See the [EKS zonal shift documentation](https://docs.aws.amazon.com/eks/latest/userguide/zone-shift.html) for more details.

### Recovery

Cancel the zonal shift:

```sh
aws arc-zonal-shift list-zonal-shifts \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME

aws arc-zonal-shift cancel-zonal-shift \
  --zonal-shift-id <ZONAL_SHIFT_ID>
```

Karpenter resumes normal operations. Nodes can be provisioned in all AZs again, and consolidation proceeds normally.

## Automate Recovery with Zonal Autoshift

The manual shift above requires a human to detect and react to AZ issues. Zonal autoshift lets AWS handle this automatically.

### Enable zonal autoshift

Create a CloudWatch alarm that ARC uses to verify your app stays healthy during practice runs:

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

Create the practice run configuration:

```sh
aws arc-zonal-shift create-practice-run-configuration \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME \
  --outcome-alarms type=CLOUDWATCH,alarmIdentifier=arn:aws:cloudwatch:$AWS_REGION:$ACCOUNT_ID:alarm:arc-zonal-shift-demo-alarm
```

Enable zonal autoshift:

```sh
aws arc-zonal-shift update-zonal-autoshift-configuration \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME \
  --zonal-autoshift-status ENABLED
```

With autoshift enabled, ARC monitors AZ health and automatically triggers a zonal shift when degradation is detected. Karpenter reacts the same way as the manual shift above. ARC also runs weekly practice shifts to verify your cluster can tolerate losing one AZ.

You can observe practice runs and autoshifts via CLI:

```sh
aws arc-zonal-shift list-autoshifts --status ACTIVE

aws arc-zonal-shift get-managed-resource \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME

aws arc-zonal-shift list-zonal-shifts \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME
```

To simulate an AZ impairment and trigger autoshift without waiting for a real incident, you can use AWS Fault Injection Service (FIS). See [Testing zonal autoshift with AWS FIS](https://docs.aws.amazon.com/r53recovery/latest/dg/testing-zonal-autoshift-fis.html).

## Cleanup

```sh
kubectl delete -f workload.yaml
kubectl delete -f workload-strict.yaml
kubectl delete -f workload-stateful.yaml
kubectl delete -f nodepool.yaml
```

Cancel any active zonal shifts:

```sh
aws arc-zonal-shift list-zonal-shifts \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME \
  --status ACTIVE

aws arc-zonal-shift cancel-zonal-shift --zonal-shift-id <ID>
```

Disable zonal autoshift if enabled:

```sh
aws arc-zonal-shift update-zonal-autoshift-configuration \
  --resource-identifier arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME \
  --zonal-autoshift-status DISABLED
```
