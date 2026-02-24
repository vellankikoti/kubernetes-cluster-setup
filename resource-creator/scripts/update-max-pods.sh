#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   EKS: ./update-max-pods.sh eks <cluster> <nodegroup> <max-pods> <launch-template-id> <launch-template-version>
#   GKE: ./update-max-pods.sh gke <cluster> <nodepool> <max-pods> [region]
#   AKS: ./update-max-pods.sh aks <cluster> <nodepool> <max-pods> <resource-group>

CLOUD="${1:-}"
CLUSTER="${2:-}"
NODEPOOL="${3:-}"
MAX_PODS="${4:-}"
ARG5="${5:-}"
ARG6="${6:-}"

if [[ -z "$CLOUD" || -z "$CLUSTER" || -z "$NODEPOOL" || -z "$MAX_PODS" ]]; then
  echo "Usage: $0 <eks|gke|aks> <cluster> <nodepool> <max-pods> [provider args]"
  exit 1
fi

case "$CLOUD" in
  eks)
    LT_ID="${ARG5:-}"
    LT_VERSION="${ARG6:-}"
    if [[ -z "$LT_ID" || -z "$LT_VERSION" ]]; then
      echo "EKS requires launch template id and version containing kubelet --max-pods=${MAX_PODS}"
      exit 1
    fi
    aws eks update-nodegroup-version \
      --cluster-name "$CLUSTER" \
      --nodegroup-name "$NODEPOOL" \
      --launch-template id="$LT_ID",version="$LT_VERSION"
    ;;
  gke)
    REGION="${ARG5:-${GCP_REGION:-us-central1}}"
    gcloud container node-pools update "$NODEPOOL" \
      --cluster "$CLUSTER" \
      --region "$REGION" \
      --max-pods-per-node "$MAX_PODS" \
      --quiet
    ;;
  aks)
    RG="${ARG5:-${AKS_RESOURCE_GROUP:-}}"
    if [[ -z "$RG" ]]; then
      echo "AKS requires resource group"
      exit 1
    fi
    az aks nodepool update \
      --cluster-name "$CLUSTER" \
      --resource-group "$RG" \
      --name "$NODEPOOL" \
      --max-pods "$MAX_PODS"
    ;;
  *)
    echo "Unsupported cloud: $CLOUD"
    exit 1
    ;;
esac
