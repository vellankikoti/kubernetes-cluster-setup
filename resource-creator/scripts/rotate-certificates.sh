#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   EKS: ./rotate-certificates.sh eks <cluster>
#   GKE: ./rotate-certificates.sh gke <cluster> [region]
#   AKS: ./rotate-certificates.sh aks <cluster> <resource-group>

CLOUD="${1:-}"
CLUSTER="${2:-}"
ARG3="${3:-}"

if [[ -z "$CLOUD" || -z "$CLUSTER" ]]; then
  echo "Usage: $0 <eks|gke|aks> <cluster> [arg]"
  exit 1
fi

case "$CLOUD" in
  eks)
    aws eks update-cluster-config --name "$CLUSTER" --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}'
    aws eks list-nodegroups --cluster-name "$CLUSTER" --output text | awk '{for(i=2;i<=NF;i++) print $i}' | while read -r ng; do
      aws eks update-nodegroup-version --cluster-name "$CLUSTER" --nodegroup-name "$ng"
    done
    ;;
  gke)
    REGION="${ARG3:-${GCP_REGION:-us-central1}}"
    gcloud container clusters update "$CLUSTER" --region "$REGION" --start-credential-rotation --quiet
    gcloud container clusters update "$CLUSTER" --region "$REGION" --complete-credential-rotation --quiet
    ;;
  aks)
    RG="${ARG3:-${AKS_RESOURCE_GROUP:-}}"
    : "${RG:?resource group required for AKS}"
    az aks rotate-certs --name "$CLUSTER" --resource-group "$RG" --yes
    ;;
  *)
    echo "Unsupported cloud: $CLOUD"
    exit 1
    ;;
esac
