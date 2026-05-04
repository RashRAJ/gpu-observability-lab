#!/bin/bash
set -e

# ============================================================
# GPU Observability - Teardown
# Removes deployed resources and optionally deletes the cluster
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKLOADS_DIR="$PROJECT_ROOT/workloads"
MONITORING_DIR="$PROJECT_ROOT/monitoring"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_step()    { echo -e "\n${CYAN}==== $1 ====${NC}\n"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warn()    { echo -e "${YELLOW}! $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }

# ============================================================
# Parse arguments
# ============================================================
usage() {
    echo "Usage: ./scripts/teardown.sh [--env <file>]"
    echo ""
    echo "Options:"
    echo "  --env <file>   Load environment variables from file"
    echo "                 Supports .env, env, or any key=value file"
    echo ""
    echo "Example:"
    echo "  ./scripts/teardown.sh --env .env"
    echo ""
    echo "Env file variables:"
    echo "  PROJECT_ID, ZONE, CLUSTER_NAME,"
    echo "  DELETE_CLUSTER"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env|-e)
            ENV_FILE="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

if [[ -n "$ENV_FILE" ]]; then
    if [[ ! -f "$ENV_FILE" ]]; then
        print_error "Env file not found: $ENV_FILE"
        exit 1
    fi
    echo "Loading environment from: $ENV_FILE"
    set -a
    source "$ENV_FILE"
    set +a
fi

# ============================================================
# Step 1: Preflight checks
# ============================================================
print_step "Step 1: Preflight Checks"

for cmd in gcloud kubectl helm; do
    if ! command -v "$cmd" &>/dev/null; then
        print_error "$cmd is not installed. Please install it first."
        exit 1
    fi
    print_success "$cmd found"
done

# ============================================================
# Step 2: Collect configuration
# ============================================================
print_step "Step 2: Configuration"

if [[ -z "$PROJECT_ID" ]]; then
    read -rp "GCP Project ID: " PROJECT_ID
fi
if [[ -z "$ZONE" ]]; then
    read -rp "Zone [us-central1-a]: " ZONE
fi
ZONE=${ZONE:-us-central1-a}
if [[ -z "$CLUSTER_NAME" ]]; then
    read -rp "Cluster name [nim-demo]: " CLUSTER_NAME
fi
CLUSTER_NAME=${CLUSTER_NAME:-nim-demo}

echo ""
echo "Target:"
echo "  Project:  $PROJECT_ID"
echo "  Zone:     $ZONE"
echo "  Cluster:  $CLUSTER_NAME"
echo ""
read -rp "Proceed with teardown? [y/N]: " CONFIRM
CONFIRM=${CONFIRM:-N}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# ============================================================
# Step 3: Connect to cluster
# ============================================================
print_step "Step 3: Fetching Cluster Credentials"

if ! gcloud container clusters describe "$CLUSTER_NAME" --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
    print_warn "Cluster '$CLUSTER_NAME' not found — skipping Kubernetes resource removal."
    SKIP_K8S=true
else
    gcloud container clusters get-credentials "$CLUSTER_NAME" \
        --zone="$ZONE" \
        --project="$PROJECT_ID"
    print_success "kubectl configured for $CLUSTER_NAME"
    SKIP_K8S=false
fi

# ============================================================
# Step 4: Remove vLLM workloads
# ============================================================
if [[ "$SKIP_K8S" != "true" ]]; then
    print_step "Step 4: Removing vLLM Workloads"

    kubectl delete -f "$MONITORING_DIR/vllm-podmonitor.yaml" --ignore-not-found
    kubectl delete -f "$WORKLOADS_DIR/vllm/mistral/deployment.yaml" --ignore-not-found
    kubectl delete -f "$WORKLOADS_DIR/vllm/mistral/pvc.yaml" --ignore-not-found
    kubectl delete secret hf-token-secret -n mistral --ignore-not-found
    kubectl delete namespace mistral --ignore-not-found
    print_success "vLLM workloads removed"

    # ============================================================
    # Step 5: Remove monitoring resources
    # ============================================================
    print_step "Step 5: Removing Monitoring Resources"

    kubectl delete -f "$MONITORING_DIR/grafana/dashboards.yaml" --ignore-not-found
    kubectl delete -f "$MONITORING_DIR/dcgm/podmonitor.yaml" --ignore-not-found
    kubectl delete -f "$MONITORING_DIR/dcgm/exporter.yaml" --ignore-not-found
    kubectl delete -f "$MONITORING_DIR/dcgm/dcgm.yaml" --ignore-not-found
    kubectl delete -f "$MONITORING_DIR/dcgm/configmap.yaml" --ignore-not-found

    if [[ -f "$MONITORING_DIR/resource-quota.yaml" ]]; then
        kubectl delete -f "$MONITORING_DIR/resource-quota.yaml" --ignore-not-found
    fi

    # nim ServiceMonitor lives in the nim namespace
    kubectl delete -f "$MONITORING_DIR/servicemonitor.yaml" --ignore-not-found
    print_success "Monitoring resources removed"

    # ============================================================
    # Step 6: Uninstall Helm chart
    # ============================================================
    print_step "Step 6: Uninstalling kube-prometheus-stack"

    if helm status kube-prometheus-stack -n observability &>/dev/null; then
        helm uninstall kube-prometheus-stack -n observability
        print_success "kube-prometheus-stack uninstalled"
    else
        print_warn "kube-prometheus-stack not found, skipping"
    fi

    # ============================================================
    # Step 7: Remove RBAC and observability namespace
    # ============================================================
    print_step "Step 7: Removing RBAC and Namespace"

    kubectl delete -f "$MONITORING_DIR/namespace.yaml" --ignore-not-found
    kubectl delete namespace observability --ignore-not-found
    print_success "observability namespace removed"
fi

# ============================================================
# Step 8: Optionally delete the GKE cluster
# ============================================================
print_step "Step 8: GKE Cluster"

if [[ -z "$DELETE_CLUSTER" ]]; then
    read -rp "Delete GKE cluster '$CLUSTER_NAME'? [y/N]: " DELETE_CLUSTER
fi
DELETE_CLUSTER=${DELETE_CLUSTER:-N}

if [[ "$DELETE_CLUSTER" =~ ^[Yy]$ ]]; then
    print_warn "Deleting cluster $CLUSTER_NAME in $ZONE..."
    gcloud container clusters delete "$CLUSTER_NAME" \
        --zone="$ZONE" \
        --project="$PROJECT_ID" \
        --quiet
    print_success "Cluster deleted"
else
    print_warn "Cluster '$CLUSTER_NAME' left intact"
fi

# ============================================================
# Done
# ============================================================
print_step "Teardown Complete"
echo "Project: $PROJECT_ID"
echo "Cluster: $CLUSTER_NAME ($ZONE)"
if [[ "$DELETE_CLUSTER" =~ ^[Yy]$ ]]; then
    echo "Status:  cluster deleted"
else
    echo "Status:  resources removed, cluster preserved"
fi
