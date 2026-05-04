#!/bin/bash
# Deploy all Grafana dashboards as ConfigMaps
# Usage: ./monitoring/deploy-dashboards.sh

NAMESPACE="observability"
FOLDER="GPU Observability"
DASHBOARD_DIR="$(dirname "$0")/grafana/dashboards"

for f in "$DASHBOARD_DIR"/*.json; do
  name="grafana-dashboard-$(basename "$f" .json)"
  echo "Deploying dashboard: $(basename "$f") -> ConfigMap/$name"
  kubectl create configmap "$name" \
    --from-file="$(basename "$f")=$f" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | \
  kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client | \
  kubectl annotate --local -f - "grafana-folder=$FOLDER" -o yaml --dry-run=client | \
  kubectl apply -f -
done
