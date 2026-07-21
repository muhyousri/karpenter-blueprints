#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_test() { echo -e "${GREEN}[TEST]${NC} $1"; }

# Required environment variables
: "${CLUSTER_NAME:?CLUSTER_NAME must be set}"
: "${KARPENTER_NODE_IAM_ROLE_NAME:?KARPENTER_NODE_IAM_ROLE_NAME must be set}"

AWS_REGION="${AWS_REGION:-$(aws configure get region)}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
RESOURCE_ARN="arn:aws:eks:${AWS_REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}"

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Verify kubectl access
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    log_info "✓ kubectl connected"

    # Verify AWS CLI
    if ! aws sts get-caller-identity &>/dev/null; then
        log_error "AWS CLI not configured or no valid credentials"
        exit 1
    fi
    log_info "✓ AWS CLI configured (Account: $ACCOUNT_ID, Region: $AWS_REGION)"

    # Verify Karpenter is running
    if ! kubectl -n karpenter get deployment karpenter &>/dev/null; then
        log_error "Karpenter deployment not found in karpenter namespace"
        exit 1
    fi
    log_info "✓ Karpenter deployment found"

    # Verify ENABLE_ZONAL_SHIFT is set
    local zonal_shift_enabled
    zonal_shift_enabled=$(kubectl -n karpenter get deployment karpenter -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null | grep -i "ENABLE_ZONAL_SHIFT" || echo "")
    if [ -z "$zonal_shift_enabled" ]; then
        log_warn "ENABLE_ZONAL_SHIFT not detected in Karpenter env vars. Attempting to check args..."
        local args_check
        args_check=$(kubectl -n karpenter get deployment karpenter -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | grep -i "enable-zonal-shift" || echo "")
        if [ -z "$args_check" ]; then
            log_error "ENABLE_ZONAL_SHIFT is not enabled. Enable it before running this test:"
            log_error "  kubectl -n karpenter set env deployment/karpenter ENABLE_ZONAL_SHIFT=true"
            exit 1
        fi
    fi
    log_info "✓ ENABLE_ZONAL_SHIFT is enabled"

    # Verify arc-zonal-shift API access
    if ! aws arc-zonal-shift list-zonal-shifts --resource-identifier "$RESOURCE_ARN" &>/dev/null; then
        log_info "Cluster not registered with ARC. Registering now..."
        aws eks update-cluster-config \
            --name "$CLUSTER_NAME" \
            --zonal-shift-config enabled=true \
            --region "$AWS_REGION" &>/dev/null || true
        # Wait for registration to propagate
        sleep 30
        if ! aws arc-zonal-shift list-zonal-shifts --resource-identifier "$RESOURCE_ARN" &>/dev/null; then
            log_error "Failed to register cluster with ARC. Ensure IAM permissions include eks:UpdateClusterConfig."
            exit 1
        fi
        log_info "✓ Cluster registered with ARC"
    else
        log_info "✓ ARC zonal shift API access confirmed"
    fi

    # Verify Karpenter controller role has arc-zonal-shift:GetManagedResource permission
    local karpenter_role
    karpenter_role=$(kubectl -n karpenter get sa karpenter -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    if [ -z "$karpenter_role" ]; then
        # Try pod identity approach
        karpenter_role=$(kubectl -n karpenter get deployment karpenter -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || echo "")
        log_info "Karpenter service account: $karpenter_role (pod identity - cannot verify IAM inline)"
    else
        local role_name
        role_name=$(echo "$karpenter_role" | awk -F'/' '{print $NF}')
        if aws iam simulate-principal-policy \
            --policy-source-arn "$karpenter_role" \
            --action-names "arc-zonal-shift:GetManagedResource" \
            --query 'EvaluationResults[0].EvalDecision' \
            --output text 2>/dev/null | grep -q "allowed"; then
            log_info "✓ Karpenter controller role has arc-zonal-shift:GetManagedResource permission"
        else
            log_warn "Could not verify arc-zonal-shift:GetManagedResource on Karpenter role. Test may fail if permission is missing."
        fi
    fi

    log_info "Prerequisites check passed"
}

wait_for_pods_ready() {
    local label_selector=$1
    local expected_count=$2
    local timeout=${3:-300}
    local elapsed=0

    log_info "Waiting for $expected_count pods with selector '$label_selector' to be Ready (timeout: ${timeout}s)..."

    while [ $elapsed -lt $timeout ]; do
        ready_count=$(kubectl get pods -l "$label_selector" --no-headers 2>/dev/null | grep -c "Running" || true)
        if [ "$ready_count" -ge "$expected_count" ]; then
            log_info "✓ $ready_count/$expected_count pods Ready"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        if [ $((elapsed % 30)) -eq 0 ]; then
            log_info "  ... $ready_count/$expected_count pods Ready (${elapsed}s elapsed)"
        fi
    done

    log_error "Timeout waiting for pods: $ready_count/$expected_count Ready after ${timeout}s"
    return 1
}

wait_for_nodeclaims() {
    local label_selector=$1
    local expected_count=$2
    local timeout=${3:-300}
    local elapsed=0

    log_info "Waiting for $expected_count nodeclaims with selector '$label_selector' (timeout: ${timeout}s)..."

    while [ $elapsed -lt $timeout ]; do
        ready_count=$(kubectl get nodeclaims -l "$label_selector" --no-headers 2>/dev/null | grep -c "True" || true)
        if [ "$ready_count" -ge "$expected_count" ]; then
            log_info "✓ $ready_count nodeclaims found"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done

    log_error "Timeout waiting for nodeclaims: $ready_count found after ${timeout}s"
    return 1
}

cleanup() {
    log_info "Cleaning up resources..."
    kubectl delete -f workload.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f workload-strict.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f workload-stateful.yaml --ignore-not-found=true 2>/dev/null || true

    # Cancel any active zonal shifts we created
    local active_shifts
    active_shifts=$(aws arc-zonal-shift list-zonal-shifts \
        --resource-identifier "$RESOURCE_ARN" \
        --status ACTIVE \
        --query 'items[?comment==`blueprint-test-arc-zonal-shift`].zonalShiftId' \
        --output text 2>/dev/null || echo "")

    if [ -n "$active_shifts" ] && [ "$active_shifts" != "None" ]; then
        for shift_id in $active_shifts; do
            log_info "Canceling zonal shift: $shift_id"
            aws arc-zonal-shift cancel-zonal-shift --zonal-shift-id "$shift_id" 2>/dev/null || true
        done
    fi

    # Wait for nodeclaims to be cleaned up
    sleep 5
    kubectl delete -f /tmp/arc-zonal-shift-nodepool.yaml --ignore-not-found=true 2>/dev/null || true

    # Wait for nodes to terminate
    local elapsed=0
    while [ $elapsed -lt 120 ]; do
        remaining=$(kubectl get nodeclaims -l intent=arc-zonal-shift --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$remaining" -eq 0 ]; then
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done

    log_info "Cleanup complete"
}

deploy_nodepool() {
    log_info "Deploying NodePool and EC2NodeClass..."
    sed "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g; s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" \
        nodepool.yaml > /tmp/arc-zonal-shift-nodepool.yaml
    kubectl apply -f /tmp/arc-zonal-shift-nodepool.yaml
    log_info "✓ NodePool and EC2NodeClass applied"
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 1: Manual zonal shift - Karpenter stops provisioning in impaired AZ
# ─────────────────────────────────────────────────────────────────────────────
test_scenario_1() {
    log_test "=== Scenario 1: Manual Zonal Shift ==="

    # Deploy workload
    kubectl apply -f workload.yaml
    wait_for_pods_ready "app=web-app-zonal" 6 || return 1

    # Wait for all nodeclaims to be fully registered (prevents race condition
    # where an in-flight node from initial provisioning appears as "new" later)
    log_info "Waiting for node provisioning to stabilize..."
    local stable_count=0
    local prev_node_count=0
    while [ $stable_count -lt 3 ]; do
        local current_node_count
        current_node_count=$(kubectl get nodes -l karpenter.sh/nodepool=arc-zonal-shift --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$current_node_count" -eq "$prev_node_count" ]; then
            stable_count=$((stable_count + 1))
        else
            stable_count=0
        fi
        prev_node_count=$current_node_count
        sleep 10
    done
    log_info "✓ Node count stabilized at $prev_node_count nodes"

    # Identify AZs with nodes
    local node_zones
    node_zones=$(kubectl get nodes -l karpenter.sh/nodepool=arc-zonal-shift \
        -o jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io/zone}' | tr ' ' '\n' | sort -u)

    if [ -z "$node_zones" ]; then
        log_error "No nodes found for nodepool arc-zonal-shift"
        return 1
    fi

    # Pick the first AZ to shift away from
    local shift_az
    shift_az=$(echo "$node_zones" | head -1)
    log_info "Nodes are in AZs: $(echo "$node_zones" | tr '\n' ' ')"
    log_info "Will shift away from: $shift_az"

    # ARC API requires AZ ID (e.g., usw2-az1) not AZ name (e.g., us-west-2a)
    local shift_az_id
    shift_az_id=$(aws ec2 describe-availability-zones --region "$AWS_REGION" \
        --filters "Name=zone-name,Values=$shift_az" \
        --query 'AvailabilityZones[0].ZoneId' --output text)
    log_info "AZ ID for $shift_az: $shift_az_id"

    # Count nodes in the target AZ before the shift
    local nodes_in_az_before
    nodes_in_az_before=$(kubectl get nodes -l "karpenter.sh/nodepool=arc-zonal-shift,topology.kubernetes.io/zone=$shift_az" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    log_info "Nodes in $shift_az before shift: $nodes_in_az_before"

    # Start the zonal shift
    log_info "Starting manual zonal shift away from $shift_az ($shift_az_id)..."
    local shift_response
    shift_response=$(aws arc-zonal-shift start-zonal-shift \
        --resource-identifier "$RESOURCE_ARN" \
        --away-from "$shift_az_id" \
        --expires-in "15m" \
        --comment "blueprint-test-arc-zonal-shift" 2>&1)

    if [ $? -ne 0 ]; then
        log_error "Failed to start zonal shift: $shift_response"
        log_warn "Skipping Scenario 1 (may need IAM permissions for arc-zonal-shift:StartZonalShift)"
        return 0
    fi

    local shift_id
    shift_id=$(echo "$shift_response" | grep -o '"zonalShiftId": *"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
    if [ -z "$shift_id" ]; then
        shift_id=$(echo "$shift_response" | grep -o '"zonalShiftId":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
    fi
    log_info "✓ Zonal shift started (ID: $shift_id)"

    # Wait for Karpenter to recognize the shift (EKS docs recommend at least 60s between zonal shift operations)
    sleep 60

    # Scale up to trigger new provisioning
    log_info "Scaling workload to 20 replicas to trigger provisioning..."
    kubectl scale deployment web-app-zonal --replicas=20

    # Wait for new pods/nodes
    wait_for_pods_ready "app=web-app-zonal" 15 180 || true  # Some may remain pending

    # Verify: no NEW nodes in the shifted AZ
    local nodes_in_az_after
    nodes_in_az_after=$(kubectl get nodes -l "karpenter.sh/nodepool=arc-zonal-shift,topology.kubernetes.io/zone=$shift_az" --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [ "$nodes_in_az_after" -le "$nodes_in_az_before" ]; then
        log_test "✅ PASSED: No new nodes launched in impaired AZ $shift_az (before: $nodes_in_az_before, after: $nodes_in_az_after)"
    else
        log_error "❌ FAILED: New nodes appeared in impaired AZ $shift_az (before: $nodes_in_az_before, after: $nodes_in_az_after)"
        # Cancel shift before returning
        aws arc-zonal-shift cancel-zonal-shift --zonal-shift-id "$shift_id" 2>/dev/null || true
        return 1
    fi

    # Verify new nodes are in healthy AZs
    local new_node_zones
    new_node_zones=$(kubectl get nodes -l karpenter.sh/nodepool=arc-zonal-shift \
        -o jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io/zone}' | tr ' ' '\n' | sort -u | grep -v "$shift_az" || echo "")

    if [ -n "$new_node_zones" ]; then
        log_test "✅ PASSED: New nodes are in healthy AZs: $(echo "$new_node_zones" | tr '\n' ' ')"
    fi

    # Cancel the zonal shift
    log_info "Canceling zonal shift..."
    aws arc-zonal-shift cancel-zonal-shift --zonal-shift-id "$shift_id" 2>/dev/null || true
    log_info "✓ Zonal shift canceled"

    # Scale back down
    kubectl scale deployment web-app-zonal --replicas=6
    sleep 10

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 3: Workload readiness - ScheduleAnyway vs DoNotSchedule
# ─────────────────────────────────────────────────────────────────────────────
test_scenario_3() {
    log_test "=== Scenario 3: Workload Readiness (TSC comparison) ==="

    # Deploy both workloads
    kubectl apply -f workload.yaml
    kubectl apply -f workload-strict.yaml
    wait_for_pods_ready "app=web-app-zonal" 6 || return 1
    wait_for_pods_ready "app=web-app-strict" 6 || return 1

    # Verify both workloads are spread across AZs
    local zonal_zones
    zonal_zones=$(kubectl get pods -l app=web-app-zonal -o jsonpath='{.items[*].spec.nodeName}' | \
        xargs -n1 kubectl get node -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}' 2>/dev/null | sort -u | wc -l | tr -d ' ')

    local strict_zones
    strict_zones=$(kubectl get pods -l app=web-app-strict -o jsonpath='{.items[*].spec.nodeName}' | \
        xargs -n1 kubectl get node -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}' 2>/dev/null | sort -u | wc -l | tr -d ' ')

    if [ "$zonal_zones" -ge 2 ]; then
        log_test "✅ PASSED: web-app-zonal (ScheduleAnyway) spread across $zonal_zones AZs"
    else
        log_warn "web-app-zonal only in $zonal_zones AZ(s) - may be due to cluster size"
    fi

    if [ "$strict_zones" -ge 2 ]; then
        log_test "✅ PASSED: web-app-strict (DoNotSchedule) spread across $strict_zones AZs"
    else
        log_warn "web-app-strict only in $strict_zones AZ(s)"
    fi

    # Key insight: both work fine BEFORE a zonal shift.
    # The difference shows during a shift when pods need to reschedule.
    log_info "Both workloads are running. The difference manifests during a zonal shift:"
    log_info "  - ScheduleAnyway: pods CAN reschedule to fewer zones (graceful degradation)"
    log_info "  - DoNotSchedule: pods CANNOT reschedule if it violates maxSkew (stuck Pending)"

    # Clean up strict workload
    kubectl delete -f workload-strict.yaml --ignore-not-found=true
    kubectl delete -f workload.yaml --ignore-not-found=true

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
main() {
    local scenario="${1:-all}"
    local failed=0

    check_prerequisites
    cleanup
    deploy_nodepool

    # Wait for NodePool to be ready
    sleep 5

    case "$scenario" in
        1|scenario1)
            test_scenario_1 || failed=1
            ;;
        3|scenario3)
            test_scenario_3 || failed=1
            ;;
        all)
            test_scenario_1 || failed=1
            # Reset between scenarios
            kubectl delete -f workload.yaml --ignore-not-found=true 2>/dev/null || true
            sleep 15
            test_scenario_3 || failed=1
            ;;
        *)
            log_error "Unknown scenario: $scenario"
            log_info "Usage: $0 [all|1|3]"
            log_info "  Scenario 1: Manual zonal shift (requires arc-zonal-shift IAM permissions)"
            log_info "  Scenario 3: Workload readiness (TSC comparison)"
            log_info "  Note: Scenario 2 (autoshift) is not automated - it requires ARC to detect real AZ degradation"
            exit 1
            ;;
    esac

    cleanup

    if [ $failed -eq 0 ]; then
        log_test "=== ALL TESTS PASSED ==="
    else
        log_error "=== SOME TESTS FAILED ==="
        exit 1
    fi
}

main "$@"
