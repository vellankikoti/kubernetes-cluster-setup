#!/usr/bin/env bash
set -euo pipefail

sanitize_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

hash8() {
  if command -v shasum >/dev/null 2>&1; then
    echo -n "$1" | shasum | awk '{print substr($1,1,8)}'
  else
    echo -n "$1" | sha1sum | awk '{print substr($1,1,8)}'
  fi
}

acquire_repo_lock() {
  local lock_dir="$1"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "another cluster operation is running in this repository: $lock_dir"
    exit 1
  fi
}

release_repo_lock() {
  local lock_dir="$1"
  rm -rf "$lock_dir"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1"; exit 1; }
}

check_aws_quotas() {
  local region="$1"
  local required_vcpu="24"

  local vcpu_quota
  vcpu_quota="$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --region "$region" --query 'Quota.Value' --output text 2>/dev/null || echo 0)"
  local vcpu_quota_int="${vcpu_quota%%.*}"
  if [[ -z "$vcpu_quota_int" || "$vcpu_quota_int" == "None" ]]; then
    echo "unable to read AWS vCPU quota"
    exit 1
  fi
  if (( vcpu_quota_int < required_vcpu )); then
    echo "insufficient AWS vCPU quota in $region: have=$vcpu_quota_int need>=$required_vcpu"
    exit 1
  fi

  local eip_quota eip_used
  eip_quota="$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3 --region "$region" --query 'Quota.Value' --output text 2>/dev/null || echo 5)"
  eip_used="$(aws ec2 describe-addresses --region "$region" --query 'length(Addresses)' --output text 2>/dev/null || echo 0)"
  local eip_quota_int="${eip_quota%%.*}"
  if (( eip_used + 2 > eip_quota_int )); then
    echo "insufficient AWS EIP quota in $region: used=$eip_used quota=$eip_quota_int"
    exit 1
  fi

  local nlb_limit nlb_used
  nlb_limit="$(aws elbv2 describe-account-limits --region "$region" --query "Limits[?Name=='network-load-balancers'].Max|[0]" --output text 2>/dev/null || echo None)"
  nlb_used="$(aws elbv2 describe-load-balancers --region "$region" --query "length(LoadBalancers[?Type=='network'])" --output text 2>/dev/null || echo 0)"
  if [[ "$nlb_limit" != "None" && "$nlb_limit" =~ ^[0-9]+$ ]]; then
    if (( nlb_used + 2 > nlb_limit )); then
      echo "insufficient AWS NLB quota in $region: used=$nlb_used limit=$nlb_limit"
      exit 1
    fi
  fi
}

check_gcp_quotas_and_apis() {
  local region="$1"
  local project_id="$2"

  local services
  services=(container.googleapis.com compute.googleapis.com iam.googleapis.com logging.googleapis.com monitoring.googleapis.com)
  gcloud services enable "${services[@]}" --project "$project_id" >/dev/null

  local quota_csv
  quota_csv="$(gcloud compute regions describe "$region" --project "$project_id" --format='csv[no-heading](quotas.metric,quotas.limit,quotas.usage)' 2>/dev/null)"

  local cpus_limit cpus_usage
  cpus_limit="$(echo "$quota_csv" | awk -F, '$1=="CPUS" {print $2; exit}')"
  cpus_usage="$(echo "$quota_csv" | awk -F, '$1=="CPUS" {print $3; exit}')"
  [[ -n "$cpus_limit" && -n "$cpus_usage" ]] || { echo "unable to read GCP CPU quota for region $region"; exit 1; }
  if (( ${cpus_limit%%.*} - ${cpus_usage%%.*} < 8 )); then
    echo "insufficient GCP CPU quota in $region: usage=$cpus_usage limit=$cpus_limit"
    exit 1
  fi

  local ip_limit ip_usage
  ip_limit="$(echo "$quota_csv" | awk -F, '$1=="IN_USE_ADDRESSES" {print $2; exit}')"
  ip_usage="$(echo "$quota_csv" | awk -F, '$1=="IN_USE_ADDRESSES" {print $3; exit}')"
  [[ -n "$ip_limit" && -n "$ip_usage" ]] || { echo "unable to read GCP IN_USE_ADDRESSES quota for region $region"; exit 1; }
  if (( ${ip_limit%%.*} - ${ip_usage%%.*} < 2 )); then
    echo "insufficient GCP in-use addresses quota in $region: usage=$ip_usage limit=$ip_limit"
    exit 1
  fi
}

check_azure_quotas() {
  local region="$1"

  local cpu_limit cpu_usage
  cpu_limit="$(az vm list-usage --location "$region" --query "[?name.value=='cores'].limit | [0]" -o tsv)"
  cpu_usage="$(az vm list-usage --location "$region" --query "[?name.value=='cores'].currentValue | [0]" -o tsv)"
  [[ -n "$cpu_limit" && -n "$cpu_usage" ]] || { echo "unable to read Azure core quota for $region"; exit 1; }
  if (( cpu_limit - cpu_usage < 8 )); then
    echo "insufficient Azure core quota in $region: usage=$cpu_usage limit=$cpu_limit"
    exit 1
  fi

  local pip_limit pip_usage
  pip_limit="$(az network list-usages --location "$region" --query "[?contains(name.value, 'PublicIPAddresses')].limit | [0]" -o tsv)"
  pip_usage="$(az network list-usages --location "$region" --query "[?contains(name.value, 'PublicIPAddresses')].currentValue | [0]" -o tsv)"
  [[ -n "$pip_limit" && -n "$pip_usage" ]] || { echo "unable to read Azure Public IP quota for $region"; exit 1; }
  if (( pip_limit - pip_usage < 2 )); then
    echo "insufficient Azure Public IP quota in $region: usage=$pip_usage limit=$pip_limit"
    exit 1
  fi
}

prepare_aws_backend() {
  local cluster_name="$1"
  local env_name="$2"
  local region="$3"
  local backend_file="$4"

  local account_id
  account_id="$(aws sts get-caller-identity --query Account --output text)"

  local bucket="rc-tfstate-${account_id}-${region}"
  local table="rc-tf-locks"
  local key="aws/${cluster_name}/${env_name}/${region}/terraform.tfstate"

  if ! aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    if [[ "$region" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$bucket" >/dev/null
    else
      aws s3api create-bucket --bucket "$bucket" --create-bucket-configuration LocationConstraint="$region" >/dev/null
    fi
  fi

  aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled >/dev/null
  aws s3api put-bucket-encryption --bucket "$bucket" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null

  if ! aws dynamodb describe-table --table-name "$table" --region "$region" >/dev/null 2>&1; then
    aws dynamodb create-table \
      --table-name "$table" \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region "$region" >/dev/null
    aws dynamodb wait table-exists --table-name "$table" --region "$region"
  fi

  cat > "$backend_file" <<HCL
bucket         = "${bucket}"
key            = "${key}"
region         = "${region}"
encrypt        = true
dynamodb_table = "${table}"
HCL
}

prepare_gcp_backend() {
  local cluster_name="$1"
  local env_name="$2"
  local region="$3"
  local project_id="$4"
  local backend_file="$5"

  local bucket
  bucket="$(sanitize_name "rc-tfstate-${project_id}")"

  if ! gcloud storage buckets describe "gs://${bucket}" --project "$project_id" >/dev/null 2>&1; then
    gcloud storage buckets create "gs://${bucket}" --project "$project_id" --location "$region" --uniform-bucket-level-access >/dev/null
  fi

  gcloud storage buckets update "gs://${bucket}" --versioning >/dev/null

  local prefix="gcp/${cluster_name}/${env_name}/${region}"
  cat > "$backend_file" <<HCL
bucket = "${bucket}"
prefix = "${prefix}"
HCL
}

prepare_azure_backend() {
  local cluster_name="$1"
  local env_name="$2"
  local region="$3"
  local subscription_id="$4"
  local backend_file="$5"

  local rg="$(sanitize_name "rc-tfstate-rg-${region}")"
  local sa="rctf$(hash8 "${subscription_id}-${region}")"
  local container="tfstate"
  local key="azure/${cluster_name}/${env_name}/${region}/terraform.tfstate"

  az group create --name "$rg" --location "$region" >/dev/null

  if ! az storage account show --name "$sa" --resource-group "$rg" >/dev/null 2>&1; then
    az storage account create \
      --name "$sa" \
      --resource-group "$rg" \
      --location "$region" \
      --sku Standard_LRS \
      --kind StorageV2 \
      --allow-blob-public-access false \
      --min-tls-version TLS1_2 >/dev/null
  fi

  az storage container create --name "$container" --account-name "$sa" --auth-mode login >/dev/null

  cat > "$backend_file" <<HCL
resource_group_name  = "${rg}"
storage_account_name = "${sa}"
container_name       = "${container}"
key                  = "${key}"
HCL
}

get_public_ip() {
  local ip
  ip="$(curl -fsS https://checkip.amazonaws.com 2>/dev/null || true)"
  ip="${ip//$'\r'/}"
  ip="${ip//$'\n'/}"
  if [[ -z "$ip" ]]; then
    ip="$(curl -fsS https://ifconfig.me 2>/dev/null || true)"
    ip="${ip//$'\r'/}"
    ip="${ip//$'\n'/}"
  fi

  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "unable to detect caller public IPv4"
    exit 1
  fi

  echo "$ip"
}

kube_api_reachable() {
  kubectl --request-timeout=10s get --raw='/readyz' >/dev/null 2>&1
}

wait_for_kube_api() {
  local attempts="${1:-30}"
  local sleep_seconds="${2:-10}"
  local i
  for i in $(seq 1 "$attempts"); do
    if kube_api_reachable; then
      return 0
    fi
    sleep "$sleep_seconds"
  done
  return 1
}

ensure_eks_public_api_access() {
  local cluster_name="$1"
  local region="$2"
  local cidr="$3"

  aws eks update-cluster-config \
    --name "$cluster_name" \
    --region "$region" \
    --resources-vpc-config endpointPrivateAccess=true,endpointPublicAccess=true,publicAccessCidrs="$cidr" >/dev/null

  aws eks wait cluster-active --name "$cluster_name" --region "$region"
}

restore_eks_private_only() {
  local cluster_name="$1"
  local region="$2"

  aws eks update-cluster-config \
    --name "$cluster_name" \
    --region "$region" \
    --resources-vpc-config endpointPrivateAccess=true,endpointPublicAccess=false >/dev/null

  aws eks wait cluster-active --name "$cluster_name" --region "$region"
}

wait_for_eks_active() {
  local cluster_name="$1"
  local region="$2"
  aws eks wait cluster-active --name "$cluster_name" --region "$region"
}

resolve_kube_context() {
  local cluster_name="$1"
  local exact=""
  local fuzzy=""

  exact="$(kubectl config get-contexts -o name 2>/dev/null | awk -v c="$cluster_name" '$0==c {print; exit}')"
  if [[ -n "$exact" ]]; then
    echo "$exact"
    return 0
  fi

  fuzzy="$(kubectl config get-contexts -o name 2>/dev/null | awk -v c="$cluster_name" 'index($0,c)>0 {print; exit}')"
  if [[ -n "$fuzzy" ]]; then
    echo "$fuzzy"
    return 0
  fi

  return 1
}
