#!/usr/bin/env bash
set -euo pipefail

CLOUD=""
NAME=""
ENV_NAME=""
REGION=""
PUBLIC_API="false"
FULL_VALIDATION="false"

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
    --full-validation)
      FULL_VALIDATION="true"
      shift 1
      ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$CLOUD" || -z "$NAME" || -z "$ENV_NAME" || -z "$REGION" ]]; then
  echo "Usage: $0 --cloud aws|gcp|azure --name <name> --env dev|qa|staging|prod --region <region> [--public-api] [--full-validation]"
  exit 1
fi

if [[ ! "$ENV_NAME" =~ ^(dev|qa|staging|prod)$ ]]; then
  echo "Invalid env: $ENV_NAME"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
LOCK_DIR="${ROOT_DIR}/scripts/.cluster-factory.lock"
trap 'rm -rf "$TMP_DIR"; source "${ROOT_DIR}/scripts/backend-lib.sh"; release_repo_lock "${LOCK_DIR}"' EXIT

source "${ROOT_DIR}/scripts/backend-lib.sh"
acquire_repo_lock "$LOCK_DIR"

"${ROOT_DIR}/scripts/preflight-check.sh" --cloud "$CLOUD" --region "$REGION"

case "$CLOUD" in
  aws)
    require_cmd aws
    check_aws_quotas "$REGION"

    ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
    SUFFIX="${ACCOUNT_ID: -6}"
    BASE_NAME="$(sanitize_name "${NAME}-aws-${SUFFIX}")"
    CLUSTER_NAME="${BASE_NAME}-${ENV_NAME}-eks"

    TF_STACK="eks"
    TF_VARS_FILE="${TMP_DIR}/vars.tfvars"
    TF_BACKEND_FILE="${TMP_DIR}/backend.hcl"

    cat > "$TF_VARS_FILE" <<TFVARS
region          = "${REGION}"
base_name       = "${BASE_NAME}"
cluster_version = "1.34"
environments    = ["${ENV_NAME}"]
TFVARS

    prepare_aws_backend "$CLUSTER_NAME" "$ENV_NAME" "$REGION" "$TF_BACKEND_FILE"
    ;;

  gcp)
    require_cmd gcloud
    CALLER_IP="$(get_public_ip)"
    PROJECT_ID="$(gcloud config get-value project 2>/dev/null | tr -d '\r')"
    [[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || { echo "gcloud project is not set"; exit 1; }

    check_gcp_quotas_and_apis "$REGION" "$PROJECT_ID"

    PROJ_HASH="$(hash8 "$PROJECT_ID")"
    BASE_NAME="$(sanitize_name "${NAME}-gcp-${PROJ_HASH}")"
    CLUSTER_NAME="${BASE_NAME}-${ENV_NAME}-gke"

    TF_STACK="gke"
    TF_VARS_FILE="${TMP_DIR}/vars.tfvars"
    TF_BACKEND_FILE="${TMP_DIR}/backend.hcl"

    if [[ "$PUBLIC_API" == "true" ]]; then
      GKE_PRIVATE_ENDPOINT="false"
      GKE_CIDRS="[\"${CALLER_IP}/32\"]"
    else
      GKE_PRIVATE_ENDPOINT="true"
      GKE_CIDRS="[\"${CALLER_IP}/32\"]"
    fi

    cat > "$TF_VARS_FILE" <<TFVARS
project_id                = "${PROJECT_ID}"
region                    = "${REGION}"
base_name                 = "${BASE_NAME}"
cluster_version           = "1.34"
environments              = ["${ENV_NAME}"]
master_authorized_cidrs   = ${GKE_CIDRS}
enable_private_endpoint   = ${GKE_PRIVATE_ENDPOINT}
TFVARS

    prepare_gcp_backend "$CLUSTER_NAME" "$ENV_NAME" "$REGION" "$PROJECT_ID" "$TF_BACKEND_FILE"
    ;;

  azure)
    require_cmd az
    SUB_ID="$(az account show --query id -o tsv)"
    check_azure_quotas "$REGION"

    SUB_HASH="$(hash8 "$SUB_ID")"
    BASE_NAME="$(sanitize_name "${NAME}-az-${SUB_HASH}")"
    CLUSTER_NAME="${BASE_NAME}-${ENV_NAME}-aks"

    TF_STACK="aks"
    TF_VARS_FILE="${TMP_DIR}/vars.tfvars"
    TF_BACKEND_FILE="${TMP_DIR}/backend.hcl"

    cat > "$TF_VARS_FILE" <<TFVARS
subscription_id = "${SUB_ID}"
region          = "${REGION}"
base_name       = "${BASE_NAME}"
cluster_version = "1.34"
environments    = ["${ENV_NAME}"]
TFVARS

    prepare_azure_backend "$CLUSTER_NAME" "$ENV_NAME" "$REGION" "$SUB_ID" "$TF_BACKEND_FILE"
    ;;

  *)
    echo "Invalid cloud: $CLOUD"
    exit 1
    ;;
esac

pushd "${ROOT_DIR}/terraform/${TF_STACK}" >/dev/null
terraform init -reconfigure -backend-config="$TF_BACKEND_FILE"
terraform apply -auto-approve -input=false -var-file="$TF_VARS_FILE"

AUTOSCALER_ROLE_ARN=""
if [[ "$CLOUD" == "aws" ]]; then
  AUTOSCALER_ROLE_ARN="$(terraform output -raw cluster_autoscaler_role_arn)"
fi
popd >/dev/null

case "$CLOUD" in
  aws)
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias "$CLUSTER_NAME" >/dev/null
    ;;
  gcp)
    if [[ "$PUBLIC_API" == "true" ]]; then
      gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$REGION" >/dev/null
    else
      gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$REGION" --internal-ip >/dev/null
    fi
    ;;
  azure)
    RG_NAME="rg-${BASE_NAME}-${ENV_NAME}-aks"
    az aks get-credentials --name "$CLUSTER_NAME" --resource-group "$RG_NAME" --overwrite-existing >/dev/null
    ;;
esac

BOOTSTRAP_ARGS=(--cloud "$CLOUD" --cluster "$CLUSTER_NAME" --region "$REGION" --env "$ENV_NAME")
if [[ -n "$AUTOSCALER_ROLE_ARN" ]]; then
  BOOTSTRAP_ARGS+=(--autoscaler-role-arn "$AUTOSCALER_ROLE_ARN")
fi
if [[ "$PUBLIC_API" == "true" ]]; then
  BOOTSTRAP_ARGS+=(--public-api)
fi
"${ROOT_DIR}/scripts/bootstrap.sh" "${BOOTSTRAP_ARGS[@]}"

VAL_ARGS=(--cloud "$CLOUD" --cluster "$CLUSTER_NAME" --region "$REGION")
if [[ "$FULL_VALIDATION" == "true" ]]; then
  VAL_ARGS+=(--full-validation)
fi
if [[ "$PUBLIC_API" == "true" ]]; then
  VAL_ARGS+=(--public-api)
fi
VAL_OUT="$(${ROOT_DIR}/scripts/validation.sh "${VAL_ARGS[@]}")"

echo "$VAL_OUT"

K8S_VER="$(kubectl version -o jsonpath='{.serverVersion.gitVersion}')"
NODE_COUNT="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
NODES_OUT="$(kubectl get nodes -o wide)"
INGRESS_ENDPOINT="$(echo "$VAL_OUT" | awk -F= '/^INGRESS_ENDPOINT=/{print $2}')"
DEFAULT_SC="$(echo "$VAL_OUT" | awk -F= '/^DEFAULT_STORAGE_CLASS=/{print $2}')"

if [[ "$CLOUD" == "aws" ]]; then
  AUTOSCALER_STATUS="$(kubectl -n kube-system get deploy cluster-autoscaler -o jsonpath='{.status.availableReplicas}')"
else
  AUTOSCALER_STATUS="native"
fi

echo ""
echo "✅ Cluster name: ${CLUSTER_NAME}"
echo "✅ Region: ${REGION}"
echo "✅ Kubernetes version: ${K8S_VER}"
echo "✅ Nodegroup size: ${NODE_COUNT}"
echo "✅ kubectl get nodes output:"
echo "${NODES_OUT}"
echo "✅ Ingress endpoint: ${INGRESS_ENDPOINT}"
echo "✅ Autoscaler status: ${AUTOSCALER_STATUS}"
echo "✅ Storage class status: ${DEFAULT_SC}"
