#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   EKS: ./scale-nodegroups.sh eks <cluster> <nodegroup> <min> <max> <desired>
#   GKE: ./scale-nodegroups.sh gke <cluster> <nodepool> <min> <max> [region]
#   AKS: ./scale-nodegroups.sh aks <cluster> <nodepool> <min> <max> <resource-group>

CLOUD="${1:-}"
CLUSTER="${2:-}"
POOL="${3:-}"
MIN="${4:-}"
MAX="${5:-}"
ARG6="${6:-}"

if [[ -z "$CLOUD" || -z "$CLUSTER" || -z "$POOL" || -z "$MIN" || -z "$MAX" ]]; then
  echo "Usage: $0 <eks|gke|aks> <cluster> <pool> <min> <max> [arg]"
  exit 1
fi

case "$CLOUD" in
  eks)
    DESIRED="${ARG6:-}"
    : "${DESIRED:?desired required for EKS}"
    aws eks update-nodegroup-config \
      --cluster-name "$CLUSTER" \
      --nodegroup-name "$POOL" \
      --scaling-config minSize="$MIN",maxSize="$MAX",desiredSize="$DESIRED"
    ;;
  gke)
    REGION="${ARG6:-${GCP_REGION:-us-central1}}"
    gcloud container clusters update "$CLUSTER" \
      --region "$REGION" \
      --node-pool "$POOL" \
      --enable-autoscaling \
      --min-nodes "$MIN" \
      --max-nodes "$MAX" \
      --quiet
    ;;
  aks)
    RG="${ARG6:-${AKS_RESOURCE_GROUP:-}}"
    : "${RG:?resource group required for AKS}"
    az aks nodepool update \
      --cluster-name "$CLUSTER" \
      --resource-group "$RG" \
      --name "$POOL" \
      --min-count "$MIN" \
      --max-count "$MAX" \
      --enable-cluster-autoscaler
    ;;
  *)
    echo "Unsupported cloud: $CLOUD"
    exit 1
    ;;
esac
