#!/bin/bash
# Test script for the CapacityBuffers blueprint
# This script validates that the blueprint works as documented in the README
#
# Prerequisites:
# - kubectl configured with access to an EKS cluster
# - Karpenter v1.14.0+ installed with the CapacityBuffer feature gate enabled
# - karpenter-crd chart at v1.14.0+ (ships the CapacityBuffer CRD)
# - Environment variables set: CLUSTER_NAME, KARPENTER_NODE_IAM_ROLE_NAME
#
# Usage: ./test.sh [scenario1|scenario2|scenario3|scenario4|all]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test configuration
TIMEOUT_NODE_READY=300  # 5 minutes (GPU nodes can take longer, handled separately)
TIMEOUT_GPU_NODE_READY=420
TIMEOUT_POD_READY=90
TIMEOUT_BUFFER_READY=90

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_test() { echo -e "${GREEN}[TEST]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found"
        exit 1
    fi

    if ! kubectl get nodes &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    # Check CapacityBuffer feature gate
    FEATURE_GATES=$(kubectl -n karpenter get deployment karpenter -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="FEATURE_GATES")].value}' 2>/dev/null || echo "")
    if [[ ! "$FEATURE_GATES" == *"CapacityBuffer=true"* ]]; then
        log_error "CapacityBuffer feature gate is not enabled in Karpenter"
        log_info "Enable it with: helm upgrade karpenter ... --set 'settings.featureGates.capacityBuffer=true'"
        exit 1
    fi

    # Check the CapacityBuffer CRD exists (ships in karpenter-crd v1.14.0+)
    if ! kubectl get crd capacitybuffers.autoscaling.x-k8s.io &> /dev/null; then
        log_error "CapacityBuffer CRD not found. Upgrade the karpenter-crd chart to v1.14.0+"
        exit 1
    fi

    if [ -z "$CLUSTER_NAME" ]; then
        export CLUSTER_NAME="karpenter-blueprints"
        log_warn "CLUSTER_NAME not set, using default: $CLUSTER_NAME"
    fi
    if [ -z "$KARPENTER_NODE_IAM_ROLE_NAME" ]; then
        export KARPENTER_NODE_IAM_ROLE_NAME="karpenter-blueprints"
        log_warn "KARPENTER_NODE_IAM_ROLE_NAME not set, using default: $KARPENTER_NODE_IAM_ROLE_NAME"
    fi

    log_info "Using cluster: $CLUSTER_NAME, IAM role: $KARPENTER_NODE_IAM_ROLE_NAME"
    log_info "Prerequisites check passed"
}

# Prepare the shared NodePool/EC2NodeClass used by scenarios 1, 2, and 4
deploy_shared_nodepool() {
    log_info "Deploying shared NodePool (reuses the cluster's default EC2NodeClass)..."
    kubectl apply -f nodepool.yaml
    kubectl apply -f podtemplate.yaml

    # The NodePool references the cluster's shared 'default' EC2NodeClass, so
    # there's no per-scenario EC2NodeClass lifecycle to wait on here. Just
    # confirm the referenced NodeClass is Ready.
    log_info "Verifying EC2NodeClass/default is Ready..."
    local ready
    ready=$(kubectl get ec2nodeclass default -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [ "$ready" != "True" ]; then
        log_error "EC2NodeClass/default is not Ready. The blueprint requires the repo's default EC2NodeClass."
        exit 1
    fi
}

cleanup_shared_nodepool() {
    kubectl delete -f nodepool.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f podtemplate.yaml --ignore-not-found=true 2>/dev/null || true
}

# Wait for a CapacityBuffer to report Provisioning=True
wait_for_buffer_provisioned() {
    local buffer_name=$1
    local timeout=$TIMEOUT_BUFFER_READY
    local elapsed=0

    log_info "Waiting for CapacityBuffer/$buffer_name to report Provisioning=True..."

    while [ $elapsed -lt $timeout ]; do
        status=$(kubectl get capacitybuffer "$buffer_name" -o jsonpath='{.status.conditions[?(@.type=="Provisioning")].status}' 2>/dev/null || echo "")
        if [ "$status" == "True" ]; then
            log_info "CapacityBuffer/$buffer_name is Provisioning=True"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    echo ""
    log_error "Timeout waiting for CapacityBuffer/$buffer_name to reach Provisioning=True"
    kubectl get capacitybuffer "$buffer_name" -o yaml 2>/dev/null || true
    return 1
}

# Wait for nodeclaim to be ready
wait_for_nodeclaim() {
    local label_selector=$1
    local expected_count=$2
    local timeout=${3:-$TIMEOUT_NODE_READY}
    local elapsed=0

    log_info "Waiting for $expected_count nodeclaim(s) with selector '$label_selector' to be ready..."

    while [ $elapsed -lt $timeout ]; do
        ready_count=$(kubectl get nodeclaims -l "$label_selector" --no-headers 2>/dev/null | grep -c "True" || true)
        ready_count=${ready_count:-0}
        ready_count=$((ready_count + 0))
        if [ "$ready_count" -ge "$expected_count" ]; then
            log_info "$ready_count nodeclaim(s) ready"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    echo ""
    log_error "Timeout waiting for nodeclaims to be ready"
    kubectl get nodeclaims -l "$label_selector" 2>/dev/null || true
    return 1
}

# Wait for pods to be running
wait_for_pods() {
    local label_selector=$1
    local expected_count=$2
    local timeout=${3:-$TIMEOUT_POD_READY}
    local elapsed=0

    log_info "Waiting for $expected_count pod(s) with selector '$label_selector' to be running..."

    while [ $elapsed -lt $timeout ]; do
        running_count=$(kubectl get pods -l "$label_selector" --no-headers 2>/dev/null | grep -c "Running" || true)
        running_count=${running_count:-0}
        running_count=$((running_count + 0))
        if [ "$running_count" -ge "$expected_count" ]; then
            log_info "$running_count pod(s) running"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    log_error "Timeout waiting for pods to be running"
    kubectl get pods -l "$label_selector" 2>/dev/null || true
    return 1
}

# ============================================================================
# SCENARIO 1: Fixed-size buffer
# ============================================================================
cleanup_scenario1() {
    log_info "Cleaning up Scenario 1..."
    kubectl delete -f capacity-buffer-fixed.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f podtemplate.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f workload.yaml --ignore-not-found=true 2>/dev/null || true
    sleep 10
}

test_scenario1() {
    log_test "=== SCENARIO 1: Fixed-size buffer ==="

    cleanup_scenario1
    deploy_shared_nodepool

    # Deploy the existing app first, before the buffer exists, to mirror the
    # real starting point: an app already running on an existing NodePool.
    log_info "Deploying web-app (already running, 2 replicas)..."
    kubectl apply -f workload.yaml
    if ! wait_for_pods "app=web-app" 2 60; then
        log_error "❌ FAILED: baseline web-app did not reach Running"
        cleanup_scenario1
        return 1
    fi

    log_info "Adding a fixed-size CapacityBuffer (3 replicas) alongside web-app..."
    kubectl apply -f podtemplate.yaml
    kubectl apply -f capacity-buffer-fixed.yaml

    if ! wait_for_buffer_provisioned "web-app-buffer"; then
        cleanup_scenario1
        return 1
    fi

    # NOTE: the 3 requested chunks (1 CPU/1Gi each) can bin-pack onto a
    # single node, or reuse slack on web-app's existing node, the same way
    # real pods with identical requests would. This is correct Karpenter
    # behavior, not a bug, so we only assert >=1 node here.
    if ! wait_for_nodeclaim "intent=capacity-buffer" 1; then
        log_error "Expected at least 1 node provisioned for the buffer"
        cleanup_scenario1
        return 1
    fi

    # Core assertion: adding the buffer never changes web-app's own pod count
    log_info "Verifying web-app's pod count is unaffected by the buffer..."
    web_app_pod_count=$(kubectl get pods -l app=web-app --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$web_app_pod_count" -ne 2 ]; then
        log_error "❌ FAILED: Expected web-app to still have 2 pods, found $web_app_pod_count"
        cleanup_scenario1
        return 1
    fi
    log_test "✅ PASSED: web-app pod count unaffected by adding the buffer"

    # Scale the real workload onto the pre-warmed capacity
    log_info "Scaling web-app to 5 replicas onto pre-warmed nodes..."
    kubectl scale deployment web-app --replicas=5

    if ! wait_for_pods "app=web-app" 5 30; then
        log_error "❌ FAILED: Pods did not become Running quickly on pre-warmed capacity"
        cleanup_scenario1
        return 1
    fi
    log_test "✅ PASSED: Real workload scheduled instantly onto pre-warmed buffer capacity"

    cleanup_scenario1
    return 0
}

# ============================================================================
# SCENARIO 2: Buffer that tracks a Deployment's size
# ============================================================================
cleanup_scenario2() {
    log_info "Cleaning up Scenario 2..."
    kubectl delete -f capacity-buffer-scalable.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f workload-scalable.yaml --ignore-not-found=true 2>/dev/null || true
    sleep 10
}

test_scenario2() {
    log_test "=== SCENARIO 2: Buffer that tracks a Deployment's size ==="

    cleanup_scenario2
    deploy_shared_nodepool

    log_info "Deploying api-service (5 replicas) and its 20% CapacityBuffer..."
    kubectl apply -f workload-scalable.yaml
    kubectl apply -f capacity-buffer-scalable.yaml

    if ! wait_for_buffer_provisioned "api-service-buffer"; then
        cleanup_scenario2
        return 1
    fi

    replicas=$(kubectl get capacitybuffer api-service-buffer -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
    log_info "Buffer replicas at 5-replica Deployment: $replicas (expected 1)"
    if [ "$replicas" != "1" ]; then
        log_error "❌ FAILED: Expected buffer replicas=1, got $replicas"
        cleanup_scenario2
        return 1
    fi

    log_info "Scaling api-service to 20 replicas..."
    kubectl scale deployment api-service --replicas=20

    log_info "Waiting up to 60s for the buffer to recalculate (30s poll interval)..."
    elapsed=0
    while [ $elapsed -lt 60 ]; do
        replicas=$(kubectl get capacitybuffer api-service-buffer -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
        if [ "$replicas" == "4" ]; then
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done

    log_info "Buffer replicas at 20-replica Deployment: $replicas (expected 4)"
    if [ "$replicas" != "4" ]; then
        log_error "❌ FAILED: Expected buffer replicas=4, got $replicas"
        cleanup_scenario2
        return 1
    fi
    log_test "✅ PASSED: Buffer recalculated proportionally as the Deployment scaled"

    cleanup_scenario2
    return 0
}

# ============================================================================
# SCENARIO 3: Pre-warming GPU capacity (with a cost cap)
# ============================================================================
cleanup_scenario3() {
    log_info "Cleaning up Scenario 3..."
    kubectl delete -f workload-gpu.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f capacity-buffer-gpu.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f gpu-podtemplate.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f /tmp/capacity-buffer-gpu-nodepool-test.yaml --ignore-not-found=true 2>/dev/null || true
    sleep 10
}

test_scenario3() {
    log_test "=== SCENARIO 3: Pre-warming GPU capacity ==="

    cleanup_scenario3

    log_info "Deploying GPU NodePool/EC2NodeClass (Bottlerocket, spot+on-demand)..."
    sed "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g; s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" gpu-nodepool.yaml > /tmp/capacity-buffer-gpu-nodepool-test.yaml
    kubectl apply -f /tmp/capacity-buffer-gpu-nodepool-test.yaml

    # NOTE: Bottlerocket's accelerated AMI variant ships the NVIDIA driver and
    # device plugin pre-installed, no separate device plugin install needed.
    kubectl apply -f gpu-podtemplate.yaml
    kubectl apply -f capacity-buffer-gpu.yaml

    if ! wait_for_nodeclaim "intent=gpu-capacity-buffer" 1 "$TIMEOUT_GPU_NODE_READY"; then
        log_error "❌ FAILED: GPU buffer node was not provisioned"
        cleanup_scenario3
        return 1
    fi

    log_info "Verifying the device plugin registered nvidia.com/gpu as allocatable..."
    elapsed=0
    gpu_alloc=0
    while [ $elapsed -lt 120 ]; do
        gpu_alloc=$(kubectl get nodes -l intent=gpu-capacity-buffer -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
        if [ -n "$gpu_alloc" ] && [ "$gpu_alloc" != "0" ]; then
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done

    if [ -z "$gpu_alloc" ] || [ "$gpu_alloc" == "0" ]; then
        log_error "❌ FAILED: nvidia.com/gpu not allocatable on the pre-warmed node"
        cleanup_scenario3
        return 1
    fi
    log_test "✅ PASSED: GPU node pre-warmed with $gpu_alloc allocatable GPU(s) before real demand arrived"

    log_info "Deploying real GPU workload..."
    kubectl apply -f workload-gpu.yaml

    local phase=""
    elapsed=0
    while [ $elapsed -lt 60 ]; do
        phase=$(kubectl get pod gpu-inference -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$phase" == "Running" ] || [ "$phase" == "Succeeded" ]; then
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ "$phase" != "Running" ] && [ "$phase" != "Succeeded" ]; then
        log_error "❌ FAILED: gpu-inference pod did not start quickly on the pre-warmed node"
        cleanup_scenario3
        return 1
    fi
    log_test "✅ PASSED: Real GPU workload started immediately on pre-warmed capacity"

    cleanup_scenario3
    return 0
}

# ============================================================================
# SCENARIO 4: Forecast-driven buffers
# ============================================================================
cleanup_scenario4() {
    log_info "Cleaning up Scenario 4..."
    kubectl delete -f workload-forecast.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f capacity-buffer-forecast.yaml --ignore-not-found=true 2>/dev/null || true
    sleep 10
}

test_scenario4() {
    log_test "=== SCENARIO 4: Forecast-driven buffers ==="

    cleanup_scenario4
    deploy_shared_nodepool

    log_info "Deploying forecast-driven buffer starting at 0 replicas..."
    kubectl apply -f capacity-buffer-forecast.yaml
    sleep 5

    log_info "Running the forecast predictor (forecast=3, lead time=30s)..."
    ./forecast-predictor.sh forecast-driven-buffer 3 30

    # NOTE: like Scenario 1, the 3 requested chunks (1 CPU/1Gi each) bin-pack
    # onto a single node, so we only assert >=1 node here.
    if ! wait_for_nodeclaim "intent=capacity-buffer" 1 120; then
        log_error "❌ FAILED: Forecast-driven buffer did not provision nodes ahead of real demand"
        cleanup_scenario4
        return 1
    fi
    log_test "✅ PASSED: Nodes were pre-provisioned during the simulated forecast window"

    log_info "Scaling the real workload to the forecasted count..."
    kubectl apply -f workload-forecast.yaml
    kubectl scale deployment web-app-forecast --replicas=3

    if ! wait_for_pods "app=web-app-forecast" 3 30; then
        log_error "❌ FAILED: Pods did not land instantly on forecast-provisioned capacity"
        cleanup_scenario4
        return 1
    fi
    log_test "✅ PASSED: Real workload landed instantly on forecast-provisioned capacity"

    cleanup_scenario4
    return 0
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    local test_target="${1:-all}"
    local exit_code=0

    check_prerequisites

    case "$test_target" in
        scenario1)
            test_scenario1 || exit_code=1
            ;;
        scenario2)
            test_scenario2 || exit_code=1
            ;;
        scenario3)
            test_scenario3 || exit_code=1
            ;;
        scenario4)
            test_scenario4 || exit_code=1
            ;;
        all)
            test_scenario1 || exit_code=1
            test_scenario2 || exit_code=1
            test_scenario3 || exit_code=1
            test_scenario4 || exit_code=1
            ;;
        *)
            echo "Usage: $0 [scenario1|scenario2|scenario3|scenario4|all]"
            exit 1
            ;;
    esac

    cleanup_shared_nodepool

    if [ $exit_code -eq 0 ]; then
        log_test "=== ALL TESTS PASSED ==="
    else
        log_error "=== SOME TESTS FAILED ==="
    fi

    exit $exit_code
}

main "$@"
