#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-}"
if [[ -z "$ENV_NAME" ]]; then
  echo "Usage: $0 <dev|qa|staging|prod>"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/environments/${ENV_NAME}.env"
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${EKS_CLUSTER_NAME:?missing EKS_CLUSTER_NAME}"
: "${GKE_CLUSTER_NAME:?missing GKE_CLUSTER_NAME}"
: "${AKS_CLUSTER_NAME:?missing AKS_CLUSTER_NAME}"
: "${AWS_REGION:?missing AWS_REGION}"
: "${GCP_REGION:?missing GCP_REGION}"
: "${GCP_PROJECT_ID:?missing GCP_PROJECT_ID}"
: "${AKS_RESOURCE_GROUP:?missing AKS_RESOURCE_GROUP}"

aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --alias "eks-${ENV_NAME}"
kubectl config use-context "eks-${ENV_NAME}"
"${ROOT_DIR}/scripts/bootstrap.sh" eks "$ENV_NAME"

gcloud container clusters get-credentials "$GKE_CLUSTER_NAME" --region "$GCP_REGION" --project "$GCP_PROJECT_ID"
"${ROOT_DIR}/scripts/bootstrap.sh" gke "$ENV_NAME"

az aks get-credentials --name "$AKS_CLUSTER_NAME" --resource-group "$AKS_RESOURCE_GROUP" --overwrite-existing
"${ROOT_DIR}/scripts/bootstrap.sh" aks "$ENV_NAME"

echo "All cloud bootstraps completed for ${ENV_NAME}"
