#!/usr/bin/env bash
set -euo pipefail

CLOUD=""
NAME=""
ENV_NAME=""
REGION=""
PUBLIC_API="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cloud)
      CLOUD="$2"
      shift 2
      ;;
    --name)
      NAME="$2"
      shift 2
      ;;
    --env)
      ENV_NAME="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --public-api)
      PUBLIC_API="true"
      shift 1
      ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$CLOUD" || -z "$NAME" || -z "$ENV_NAME" || -z "$REGION" ]]; then
  echo "Usage: $0 --cloud aws|gcp|azure --name <name> --env dev|qa|staging|prod --region <region> [--public-api]"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
LOCK_DIR="${ROOT_DIR}/scripts/.cluster-factory.lock"
trap 'rm -rf "$TMP_DIR"; source "${ROOT_DIR}/scripts/backend-lib.sh"; release_repo_lock "${LOCK_DIR}"' EXIT

source "${ROOT_DIR}/scripts/backend-lib.sh"
acquire_repo_lock "$LOCK_DIR"

TF_VARS_FILE="${TMP_DIR}/vars.tfvars"
TF_BACKEND_FILE="${TMP_DIR}/backend.hcl"

case "$CLOUD" in
  aws)
    ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
    SUFFIX="${ACCOUNT_ID: -6}"
    BASE_NAME="$(sanitize_name "${NAME}-aws-${SUFFIX}")"
    CLUSTER_NAME="${BASE_NAME}-${ENV_NAME}-eks"

    cat > "$TF_VARS_FILE" <<TFVARS
region          = "${REGION}"
base_name       = "${BASE_NAME}"
cluster_version = "1.34"
environments    = ["${ENV_NAME}"]
TFVARS

    prepare_aws_backend "$CLUSTER_NAME" "$ENV_NAME" "$REGION" "$TF_BACKEND_FILE"
    TF_STACK="eks"
    ;;

  gcp)
    PROJECT_ID="$(gcloud config get-value project 2>/dev/null | tr -d '\r')"
    [[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || { echo "gcloud project is not set"; exit 1; }
    CALLER_IP="$(get_public_ip)"
    PROJ_HASH="$(hash8 "$PROJECT_ID")"
    BASE_NAME="$(sanitize_name "${NAME}-gcp-${PROJ_HASH}")"
    CLUSTER_NAME="${BASE_NAME}-${ENV_NAME}-gke"

    if [[ "$PUBLIC_API" == "true" ]]; then
      GKE_PRIVATE_ENDPOINT="false"
    else
      GKE_PRIVATE_ENDPOINT="true"
    fi

    cat > "$TF_VARS_FILE" <<TFVARS
project_id                = "${PROJECT_ID}"
region                    = "${REGION}"
base_name                 = "${BASE_NAME}"
cluster_version           = "1.34"
environments              = ["${ENV_NAME}"]
master_authorized_cidrs   = ["${CALLER_IP}/32"]
enable_private_endpoint   = ${GKE_PRIVATE_ENDPOINT}
TFVARS

    prepare_gcp_backend "$CLUSTER_NAME" "$ENV_NAME" "$REGION" "$PROJECT_ID" "$TF_BACKEND_FILE"
    TF_STACK="gke"
    ;;

  azure)
    SUB_ID="$(az account show --query id -o tsv)"
    SUB_HASH="$(hash8 "$SUB_ID")"
    BASE_NAME="$(sanitize_name "${NAME}-az-${SUB_HASH}")"
    CLUSTER_NAME="${BASE_NAME}-${ENV_NAME}-aks"

    cat > "$TF_VARS_FILE" <<TFVARS
subscription_id = "${SUB_ID}"
region          = "${REGION}"
base_name       = "${BASE_NAME}"
cluster_version = "1.34"
environments    = ["${ENV_NAME}"]
TFVARS

    prepare_azure_backend "$CLUSTER_NAME" "$ENV_NAME" "$REGION" "$SUB_ID" "$TF_BACKEND_FILE"
    TF_STACK="aks"
    ;;

  *)
    echo "Invalid cloud: $CLOUD"
    exit 1
    ;;
esac

pushd "${ROOT_DIR}/terraform/${TF_STACK}" >/dev/null
terraform init -reconfigure -backend-config="$TF_BACKEND_FILE"
terraform destroy -auto-approve -input=false -var-file="$TF_VARS_FILE"
popd >/dev/null

echo "Destroyed ${CLOUD} cluster set for name=${NAME} env=${ENV_NAME} region=${REGION}"
