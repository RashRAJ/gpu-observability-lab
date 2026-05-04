#!/bin/bash
set -e

# ============================================================
# GPU Observability - Full Stack Setup
# Creates GKE cluster, deploys LLM, and sets up monitoring
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKLOADS_DIR="$PROJECT_ROOT/workloads"
MONITORING_DIR="$PROJECT_ROOT/monitoring"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_step() { echo -e "\n${CYAN}==== $1 ====${NC}\n"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warn() { echo -e "${YELLOW}! $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }

# ============================================================
# Parse arguments
# ============================================================
usage() {
    echo "Usage: ./scripts/setup.sh [--env <file>]"
    echo ""
    echo "Options:"
    echo "  --env <file>   Load environment variables from file"
    echo "                 Supports .env, env, or any key=value file"
    echo ""
    echo "Example:"
    echo "  ./scripts/setup.sh --env .env"
    echo ""
    echo "Env file variables:"
    echo "  PROJECT_ID, ZONE, CLUSTER_NAME, GPU_TYPE, GPU_COUNT,"
    echo "  NODE_POOL_MACHINE_TYPE, NUM_NODES, HF_TOKEN,"
    echo "  DISABLE_DCGM, DEPLOY_MONITORING, DEPLOY_DASHBOARDS,"
    echo "  DISABLE_GRAFANA_DEFAULT_DASHBOARDS"
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

# Load env file if provided
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

# Check gke-gcloud-auth-plugin
if ! gcloud components list --filter="id=gke-gcloud-auth-plugin" --format="value(state.name)" 2>/dev/null | grep -q "Installed"; then
    print_warn "gke-gcloud-auth-plugin not found. Installing..."
    gcloud components install gke-gcloud-auth-plugin || {
        print_warn "gcloud install failed, trying brew..."
        brew install gke-gcloud-auth-plugin
    }
fi
print_success "gke-gcloud-auth-plugin ready"

# ============================================================
# Step 2: Collect configuration
# ============================================================
print_step "Step 2: Configuration"

# Prompt only for variables not already set (e.g. from --env file)
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
if [[ -z "$GPU_TYPE" ]]; then
    read -rp "GPU type [nvidia-l4]: " GPU_TYPE
fi
GPU_TYPE=${GPU_TYPE:-nvidia-l4}
if [[ -z "$GPU_COUNT" ]]; then
    read -rp "GPU count [1]: " GPU_COUNT
fi
GPU_COUNT=${GPU_COUNT:-1}
if [[ -z "$NODE_POOL_MACHINE_TYPE" ]]; then
    read -rp "Machine type [g2-standard-4]: " NODE_POOL_MACHINE_TYPE
fi
NODE_POOL_MACHINE_TYPE=${NODE_POOL_MACHINE_TYPE:-g2-standard-4}
if [[ -z "$NUM_NODES" ]]; then
    read -rp "Number of nodes [1]: " NUM_NODES
fi
NUM_NODES=${NUM_NODES:-1}

echo ""
echo "Cluster config:"
echo "  Project:      $PROJECT_ID"
echo "  Zone:         $ZONE"
echo "  Cluster:      $CLUSTER_NAME"
echo "  GPU:          $GPU_TYPE x$GPU_COUNT"
echo "  Machine type: $NODE_POOL_MACHINE_TYPE"
echo "  Nodes:        $NUM_NODES"
echo ""
read -rp "Proceed? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# ============================================================
# Step 3: Create GKE cluster (or connect to existing)
# ============================================================
print_step "Step 3: Creating GKE Cluster"

# Check if cluster already exists
if gcloud container clusters describe "$CLUSTER_NAME" --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
    print_warn "Cluster '$CLUSTER_NAME' already exists, skipping creation"
else
    if [[ -z "$DISABLE_DCGM" ]]; then
        read -rp "Disable GKE managed DCGM? (use your own exporter) [y/N]: " DISABLE_DCGM
    fi
    DISABLE_DCGM=${DISABLE_DCGM:-N}

    if [[ "$DISABLE_DCGM" =~ ^[Yy]$ ]]; then
        gcloud container clusters create "$CLUSTER_NAME" \
            --project="$PROJECT_ID" \
            --zone="$ZONE" \
            --accelerator type="$GPU_TYPE",count="$GPU_COUNT",gpu-driver-version=latest \
            --machine-type="$NODE_POOL_MACHINE_TYPE" \
            --num-nodes="$NUM_NODES" \
            --monitoring=SYSTEM
    else
        gcloud container clusters create "$CLUSTER_NAME" \
            --project="$PROJECT_ID" \
            --zone="$ZONE" \
            --accelerator type="$GPU_TYPE",count="$GPU_COUNT",gpu-driver-version=latest \
            --machine-type="$NODE_POOL_MACHINE_TYPE" \
            --num-nodes="$NUM_NODES"
    fi

    print_success "Cluster created"
fi

# ============================================================
# Step 4: Get cluster credentials
# ============================================================
print_step "Step 4: Fetching Cluster Credentials"

gcloud container clusters get-credentials "$CLUSTER_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID"

print_success "kubectl configured for $CLUSTER_NAME"

# Label GPU nodes
kubectl label nodes --all nvidia.com/gpu=true --overwrite
print_success "Nodes labeled"

# ============================================================
# Step 5: Deploy monitoring stack
# ============================================================
print_step "Step 5: Deploying Monitoring Stack"

if [[ -z "$DEPLOY_MONITORING" ]]; then
    read -rp "Deploy monitoring (Prometheus + Grafana + DCGM)? [Y/n]: " DEPLOY_MONITORING
fi
DEPLOY_MONITORING=${DEPLOY_MONITORING:-Y}

if [[ "$DEPLOY_MONITORING" =~ ^[Yy]$ ]]; then
    # Create observability namespace and service account
    kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
    kubectl create serviceaccount observability-sa -n observability --dry-run=client -o yaml | kubectl apply -f -

    # RBAC
    if [[ -f "$MONITORING_DIR/namespace.yaml" ]]; then
        kubectl apply -f "$MONITORING_DIR/namespace.yaml"
    fi

    # Install kube-prometheus-stack
    echo ""
    print_warn "Installing kube-prometheus-stack via Helm..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update

    if [[ -z "$DISABLE_GRAFANA_DEFAULT_DASHBOARDS" ]]; then
        read -rp "Disable default Grafana dashboards (kubernetes/node/etc)? [y/N]: " DISABLE_GRAFANA_DEFAULT_DASHBOARDS
    fi
    DISABLE_GRAFANA_DEFAULT_DASHBOARDS=${DISABLE_GRAFANA_DEFAULT_DASHBOARDS:-N}

    GRAFANA_DASHBOARDS_FLAG=""
    if [[ "$DISABLE_GRAFANA_DEFAULT_DASHBOARDS" =~ ^[Yy]$ ]]; then
        GRAFANA_DASHBOARDS_FLAG="--set grafana.defaultDashboardsEnabled=false"
    fi

    if helm status kube-prometheus-stack -n observability &>/dev/null; then
        print_warn "kube-prometheus-stack already installed, upgrading..."
        helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
            --version 82.13.6 \
            --namespace observability \
            --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
            --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
            $GRAFANA_DASHBOARDS_FLAG
    else
        helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
            --version 82.13.6 \
            --namespace observability \
            --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
            --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
            $GRAFANA_DASHBOARDS_FLAG
    fi
    print_success "kube-prometheus-stack installed"

    # Deploy DCGM stack (host engine, metrics configmap, exporter)
    echo ""
    print_warn "Deploying DCGM stack..."
    kubectl apply -f "$MONITORING_DIR/dcgm/configmap.yaml"
    kubectl apply -f "$MONITORING_DIR/dcgm/dcgm.yaml"
    kubectl apply -f "$MONITORING_DIR/dcgm/exporter.yaml"
    print_success "DCGM stack deployed (host engine + exporter + custom metrics)"

    # Resource quota for system-critical pods
    if [[ -f "$MONITORING_DIR/resource-quota.yaml" ]]; then
        kubectl apply -f "$MONITORING_DIR/resource-quota.yaml"
        print_success "Resource quota applied"
    fi

    # PodMonitor for DCGM
    kubectl apply -f "$MONITORING_DIR/dcgm/podmonitor.yaml"
    print_success "DCGM PodMonitor created"

    # Deploy Grafana dashboards
    if [[ -z "$DEPLOY_DASHBOARDS" ]]; then
        read -rp "Deploy pre-built Grafana dashboards? [Y/n]: " DEPLOY_DASHBOARDS
    fi
    DEPLOY_DASHBOARDS=${DEPLOY_DASHBOARDS:-Y}

    if [[ "$DEPLOY_DASHBOARDS" =~ ^[Yy]$ ]]; then
        echo ""
        print_warn "Deploying Grafana dashboards..."
        if [[ -f "$MONITORING_DIR/grafana/dashboards.yaml" ]]; then
            kubectl apply -f "$MONITORING_DIR/grafana/dashboards.yaml"
        fi
        if [[ -x "$MONITORING_DIR/deploy-dashboards.sh" ]]; then
            bash "$MONITORING_DIR/deploy-dashboards.sh"
        fi
        print_success "Grafana dashboards deployed"
    else
        print_warn "Skipping Grafana dashboard deployment"
    fi
else
    print_warn "Skipping monitoring setup"
fi

# ============================================================
# Step 6: Deploy Mistral 7B
# ============================================================
print_step "Step 6: Deploying vLLM - Mistral 7B"

if [[ -z "$HF_TOKEN" ]]; then
    read -rsp "Hugging Face Token: " HF_TOKEN
    echo ""
fi

kubectl create namespace mistral --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic hf-token-secret \
    --from-literal=token="$HF_TOKEN" \
    -n mistral --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$WORKLOADS_DIR/vllm/mistral/pvc.yaml"
kubectl apply -f "$WORKLOADS_DIR/vllm/mistral/deployment.yaml"

kubectl apply -f "$MONITORING_DIR/vllm-podmonitor.yaml"

print_success "vLLM Mistral 7B deployed to namespace 'mistral'"

# ============================================================
# Step 7: Summary
# ============================================================
print_step "Setup Complete"

echo "Cluster:     $CLUSTER_NAME ($ZONE)"
echo "Project:     $PROJECT_ID"
echo ""

echo "Pods:"
kubectl get pods --all-namespaces --field-selector=status.phase!=Succeeded -o wide 2>/dev/null || true
echo ""

if [[ "$DEPLOY_MONITORING" =~ ^[Yy]$ ]]; then
    echo ""
    echo "------------------------------------------------------------"
    echo "Access Grafana:"
    echo ""
    echo "  # Get admin password"
    echo "  kubectl -n observability get secrets kube-prometheus-stack-grafana \\"
    echo "    -o jsonpath=\"{.data.admin-password}\" | base64 -d; echo"
    echo ""
    echo "  # Port forward"
    echo "  kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80"
    echo ""
    echo "  # Open http://localhost:3000 (user: admin)"
    echo "------------------------------------------------------------"
fi

echo ""
echo "------------------------------------------------------------"
echo "Test Mistral API:"
echo ""
echo "  kubectl -n mistral port-forward \\"
echo "    \$(kubectl get pod -n mistral -l app=mistral-7b -o jsonpath='{.items[0].metadata.name}') \\"
echo "    8000:8000"
echo ""
echo "  curl http://localhost:8000/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"mistralai/Mistral-7B-Instruct-v0.3\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}]}'"
echo "------------------------------------------------------------"

echo ""
echo "------------------------------------------------------------"
echo "Cleanup: gcloud container clusters delete $CLUSTER_NAME --zone=$ZONE"
echo "------------------------------------------------------------"
