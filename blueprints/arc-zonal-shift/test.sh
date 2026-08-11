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

AWS_REGION="${AWS_REGION:-$(aws configure get region)}"
export AWS_DEFAULT_REGION="$AWS_REGION"
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
        local args_check
        args_check=$(kubectl -n karpenter get deployment karpenter -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | grep -i "enable-zonal-shift" || echo "")
        if [ -z "$args_check" ]; then
            log_error "ENABLE_ZONAL_SHIFT is not enabled. Enable it before running this test:"
            log_error "  kubectl -n karpenter set env deployment/karpenter ENABLE_ZONAL_SHIFT=true"
            exit 1
        fi
    fi
    log_info "✓ ENABLE_ZONAL_SHIFT is enabled"

    # Verify arc-zonal-shift API access and register if needed
    if ! aws arc-zonal-shift list-zonal-shifts --resource-identifier "$RESOURCE_ARN" &>/dev/null; then
        log_info "Cluster not registered with ARC. Registering now..."
        aws eks update-cluster-config \
            --name "$CLUSTER_NAME" \
            --zonal-shift-config enabled=true \
            --region "$AWS_REGION" &>/dev/null || true
        sleep 30
        if ! aws arc-zonal-shift list-zonal-shifts --resource-identifier "$RESOURCE_ARN" &>/dev/null; then
            log_error "Failed to register cluster with ARC. Ensure IAM permissions include eks:UpdateClusterConfig."
            exit 1
        fi
        log_info "✓ Cluster registered with ARC"
    else
        log_info "✓ ARC zonal shift API access confirmed"
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

cleanup() {
    log_info "Cleaning up resources..."
    kubectl delete -f workload.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f workload-strict.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f workload-stateful.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f nodepool.yaml --ignore-not-found=true 2>/dev/null || true

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

    log_info "Cleanup complete"
}

# ---------------------------------------------------------------------------
# Main test: single incident story
# ---------------------------------------------------------------------------
run_test() {
    log_test "=== Deploy all workloads ==="

    kubectl apply -f nodepool.yaml
    kubectl apply -f workload.yaml
    kubectl apply -f workload-strict.yaml
    kubectl apply -f workload-stateful.yaml

    wait_for_pods_ready "app=web-app-zonal" 6 || return 1
    wait_for_pods_ready "app=web-app-strict" 6 || return 1

    # Wait for node provisioning to stabilize
    # Wait until all NodeClaims have registered as Ready nodes
    log_info "Waiting for node provisioning to stabilize..."
    local elapsed=0
    while [ $elapsed -lt 300 ]; do
        local nodeclaims
        local nodes
        nodeclaims=$(kubectl get nodeclaims -l karpenter.sh/nodepool=arc-zonal-shift --no-headers 2>/dev/null | wc -l | tr -d ' ')
        nodes=$(kubectl get nodes -l karpenter.sh/nodepool=arc-zonal-shift --no-headers 2>/dev/null | grep -c " Ready" || true)
        if [ "$nodeclaims" -gt 0 ] && [ "$nodeclaims" -eq "$nodes" ]; then
            log_info "✓ All $nodeclaims NodeClaims have Ready nodes"
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    if [ $elapsed -ge 300 ]; then
        log_warn "Timeout waiting for NodeClaims to match Ready nodes (nodeclaims=$nodeclaims, ready_nodes=$nodes)"
    fi

    # Identify AZs with nodes
    local node_zones
    node_zones=$(kubectl get nodes -l karpenter.sh/nodepool=arc-zonal-shift \
        -o jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io/zone}' | tr ' ' '\n' | sort -u)

    if [ -z "$node_zones" ]; then
        log_error "No nodes found for nodepool arc-zonal-shift"
        return 1
    fi

    # Pick the AZ where the stateful pod is running (ensures EBS limitation is demonstrated)
    local shift_az
    shift_az=$(kubectl get pod -l app=web-app-stateful -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null | \
        xargs kubectl get node -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null)
    log_info "Nodes are in AZs: $(echo "$node_zones" | tr '\n' ' ')"
    log_info "Will shift away from: $shift_az"

    # ARC API requires AZ ID (e.g., usw2-az1) not AZ name (e.g., us-west-2a)
    local shift_az_id
    shift_az_id=$(aws ec2 describe-availability-zones --region "$AWS_REGION" \
        --filters "Name=zone-name,Values=$shift_az" \
        --query 'AvailabilityZones[0].ZoneId' --output text)
    log_info "AZ ID for $shift_az: $shift_az_id"

    # Count nodes in target AZ before the shift
    local nodes_in_az_before
    nodes_in_az_before=$(kubectl get nodes -l "karpenter.sh/nodepool=arc-zonal-shift,topology.kubernetes.io/zone=$shift_az" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    log_info "Nodes in $shift_az before shift: $nodes_in_az_before"

    # --- Trigger the zonal shift ---
    log_test "=== Trigger zonal shift ==="

    local shift_response
    shift_response=$(aws arc-zonal-shift start-zonal-shift \
        --resource-identifier "$RESOURCE_ARN" \
        --away-from "$shift_az_id" \
        --expires-in "15m" \
        --comment "blueprint-test-arc-zonal-shift" 2>&1)

    if [ $? -ne 0 ]; then
        log_error "Failed to start zonal shift: $shift_response"
        return 1
    fi

    local shift_id
    shift_id=$(echo "$shift_response" | grep -o '"zonalShiftId": *"[^"]*"' | cut -d'"' -f4 2>/dev/null || true)
    if [ -z "$shift_id" ]; then
        shift_id=$(echo "$shift_response" | grep -o '"zonalShiftId":"[^"]*"' | cut -d'"' -f4 2>/dev/null || true)
    fi
    log_info "✓ Zonal shift started (ID: $shift_id)"

    # Wait for Karpenter to recognize the shift
    log_info "Waiting 60s for Karpenter to process the zonal shift..."
    sleep 60

    # --- Test flexible workload ---
    log_test "=== Flexible workload (ScheduleAnyway) ==="

    kubectl scale deployment web-app-zonal --replicas=12
    wait_for_pods_ready "app=web-app-zonal" 10 180 || true

    # Verify no new nodes in shifted AZ
    local nodes_in_az_after
    nodes_in_az_after=$(kubectl get nodes -l "karpenter.sh/nodepool=arc-zonal-shift,topology.kubernetes.io/zone=$shift_az" --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [ "$nodes_in_az_after" -le "$nodes_in_az_before" ]; then
        log_test "✅ PASSED: No new nodes launched in impaired AZ $shift_az (before: $nodes_in_az_before, after: $nodes_in_az_after)"
    else
        log_error "❌ FAILED: New nodes appeared in impaired AZ $shift_az (before: $nodes_in_az_before, after: $nodes_in_az_after)"
        aws arc-zonal-shift cancel-zonal-shift --zonal-shift-id "$shift_id" 2>/dev/null || true
        return 1
    fi

    # --- Test strict workload ---
    log_test "=== Strict workload (DoNotSchedule) ==="

    kubectl scale deployment web-app-strict --replicas=12
    sleep 30

    local pending_strict
    pending_strict=$(kubectl get pods -l app=web-app-strict --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [ "$pending_strict" -gt 0 ]; then
        log_test "✅ PASSED: $pending_strict strict pods stuck Pending (DoNotSchedule blocks scaling during shift)"
        # Verify the reason is topology spread constraints
        local tsc_event
        tsc_event=$(kubectl get events --field-selector reason=FailedScheduling -o json 2>/dev/null | grep -i "topology spread" || true)
        if [ -n "$tsc_event" ]; then
            log_test "✅ PASSED: FailedScheduling event confirms topology spread constraint"
        else
            log_warn "Could not confirm topology spread in FailedScheduling events"
        fi
    else
        log_warn "No strict pods Pending - all scheduled (cluster may have enough capacity in healthy AZs)"
    fi

    # --- Test stateful workload ---
    log_test "=== Stateful workload (EBS volume affinity) ==="

    kubectl delete pod -l app=web-app-stateful 2>/dev/null || true
    sleep 15

    local stateful_status
    stateful_status=$(kubectl get pods -l app=web-app-stateful -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")

    if [ "$stateful_status" == "Pending" ]; then
        log_test "✅ PASSED: Stateful pod stuck Pending (EBS volume pinned to impaired AZ)"
    else
        log_error "❌ FAILED: Stateful pod status: $stateful_status (expected Pending)"
        return 1
    fi

    # --- Recovery ---
    log_test "=== Recovery ==="

    log_info "Canceling zonal shift..."
    aws arc-zonal-shift cancel-zonal-shift --zonal-shift-id "$shift_id" 2>/dev/null || true
    log_info "✓ Zonal shift canceled. Karpenter resumes normal operations."

    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    check_prerequisites
    cleanup
    run_test || { cleanup; log_error "=== TEST FAILED ==="; exit 1; }
    cleanup
    log_test "=== ALL TESTS PASSED ==="
}

main "$@"
