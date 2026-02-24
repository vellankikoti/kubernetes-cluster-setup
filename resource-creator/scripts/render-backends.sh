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

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?missing AWS_ACCOUNT_ID}"
AWS_REGION="${AWS_REGION:?missing AWS_REGION}"
GCP_PROJECT_ID="${GCP_PROJECT_ID:?missing GCP_PROJECT_ID}"
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:?missing AZURE_SUBSCRIPTION_ID}"

# deterministic names; create these resources once using platform bootstrap controls.
EKS_BUCKET="tfstate-${AWS_ACCOUNT_ID}-${AWS_REGION}"
GKE_BUCKET="${GCP_PROJECT_ID}-tfstate"
AKS_RG="rg-tfstate-${ENV_NAME}"
AKS_STORAGE_ACCOUNT="tfstate${AZURE_SUBSCRIPTION_ID//-/}"
AKS_STORAGE_ACCOUNT="${AKS_STORAGE_ACCOUNT:0:24}"
AKS_CONTAINER="tfstate"

mkdir -p "${ROOT_DIR}/terraform/eks/env" "${ROOT_DIR}/terraform/gke/env" "${ROOT_DIR}/terraform/aks/env" "${ROOT_DIR}/terraform/vcluster/env"

cat > "${ROOT_DIR}/terraform/eks/env/${ENV_NAME}.backend.hcl" <<HCL
bucket         = "${EKS_BUCKET}"
key            = "${ENV_NAME}/eks/terraform.tfstate"
region         = "${AWS_REGION}"
encrypt        = true
dynamodb_table = "terraform-locks"
HCL

cat > "${ROOT_DIR}/terraform/vcluster/env/${ENV_NAME}.backend.hcl" <<HCL
bucket         = "${EKS_BUCKET}"
key            = "${ENV_NAME}/vcluster/terraform.tfstate"
region         = "${AWS_REGION}"
encrypt        = true
dynamodb_table = "terraform-locks"
HCL

cat > "${ROOT_DIR}/terraform/gke/env/${ENV_NAME}.backend.hcl" <<HCL
bucket = "${GKE_BUCKET}"
prefix = "${ENV_NAME}/gke"
HCL

cat > "${ROOT_DIR}/terraform/aks/env/${ENV_NAME}.backend.hcl" <<HCL
resource_group_name  = "${AKS_RG}"
storage_account_name = "${AKS_STORAGE_ACCOUNT}"
container_name       = "${AKS_CONTAINER}"
key                  = "${ENV_NAME}/aks/terraform.tfstate"
HCL

echo "Rendered backend config files for ${ENV_NAME}"
