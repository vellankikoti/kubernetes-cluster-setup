#!/usr/bin/env bash
set -euo pipefail

CLOUD=""
CLUSTER_NAME=""
REGION=""
ENV_NAME=""
AUTOSCALER_ROLE_ARN=""
PUBLIC_API="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cloud)
      CLOUD="$2"
      shift 2
      ;;
    --cluster)
      CLUSTER_NAME="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --env)
      ENV_NAME="$2"
      shift 2
      ;;
    --autoscaler-role-arn)
      AUTOSCALER_ROLE_ARN="$2"
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

if [[ -z "$CLOUD" || -z "$CLUSTER_NAME" || -z "$REGION" || -z "$ENV_NAME" ]]; then
  echo "Usage: $0 --cloud aws|gcp|azure --cluster <name> --region <region> --env dev|qa|staging|prod [--autoscaler-role-arn <arn>] [--public-api]"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
source "${ROOT_DIR}/scripts/backend-lib.sh"
PREV_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
TARGET_CONTEXT=""

AWS_PUBLIC_API_TEMP_ENABLED="false"
cleanup() {
  if [[ "$CLOUD" == "aws" && "$PUBLIC_API" == "true" && "$AWS_PUBLIC_API_TEMP_ENABLED" == "true" ]]; then
    # Best practice: keep EKS API private by default. Public API is temporary for operator access only.
    restore_eks_private_only "$CLUSTER_NAME" "$REGION" || true
  fi
  if [[ -n "$PREV_CONTEXT" ]]; then
    kubectl config use-context "$PREV_CONTEXT" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

for c in kubectl helm; do
  command -v "$c" >/dev/null 2>&1 || { echo "missing command: $c"; exit 1; }
done

if [[ "$CLOUD" == "aws" ]]; then
  command -v aws >/dev/null 2>&1 || { echo "missing command: aws"; exit 1; }
  wait_for_eks_active "$CLUSTER_NAME" "$REGION"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias "$CLUSTER_NAME" >/dev/null

  if ! kube_api_reachable; then
    if [[ "$PUBLIC_API" == "true" ]]; then
      CALLER_IP="$(get_public_ip)"
      ensure_eks_public_api_access "$CLUSTER_NAME" "$REGION" "${CALLER_IP}/32"
      AWS_PUBLIC_API_TEMP_ENABLED="true"
      if ! wait_for_kube_api 36 10; then
        echo "EKS API still unreachable after enabling temporary public endpoint."
        echo "Likely DNS propagation or network egress restriction from this machine."
        echo "Retry in 2-3 minutes, or run from a network with direct internet egress."
        exit 1
      fi
    else
      echo "Kubernetes API is unreachable. This EKS cluster is private-only."
      echo "Run from a network path that can reach the VPC (VPN/bastion/private runner),"
      echo "or re-run bootstrap with --public-api for temporary, CIDR-restricted access."
      exit 1
    fi
  fi
fi

TARGET_CONTEXT="$(resolve_kube_context "$CLUSTER_NAME" || true)"
if [[ -z "$TARGET_CONTEXT" ]]; then
  echo "unable to resolve kube context for cluster: $CLUSTER_NAME"
  exit 1
fi

kctl() {
  kubectl --context "$TARGET_CONTEXT" "$@"
}

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
helm repo add autoscaler https://kubernetes.github.io/autoscaler >/dev/null
helm repo update >/dev/null

# Best practice: don't render ServiceMonitor resources unless Prometheus Operator CRDs exist.
# Fresh clusters in this factory do not install kube-prometheus-stack in bootstrap by default.
NGINX_EXTRA_VALUES=""
if ! kctl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  cat > "${TMP_DIR}/nginx-no-servicemonitor.yaml" <<YAML
controller:
  metrics:
    serviceMonitor:
      enabled: false
YAML
  NGINX_EXTRA_VALUES="-f ${TMP_DIR}/nginx-no-servicemonitor.yaml"
fi

kctl apply -f "${ROOT_DIR}/common-resources/namespaces.yaml"
kctl apply -f "${ROOT_DIR}/common-resources/priority-classes.yaml"
kctl apply -f "${ROOT_DIR}/common-resources/network-policies.yaml"
kctl apply -f "${ROOT_DIR}/common-resources/resource-quotas.yaml"
kctl apply -f "${ROOT_DIR}/common-resources/limit-ranges.yaml"
kctl apply -f "${ROOT_DIR}/common-resources/pod-disruption-budgets.yaml"

if [[ -n "$NGINX_EXTRA_VALUES" ]]; then
  # shellcheck disable=SC2086
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx --create-namespace \
    --kube-context "$TARGET_CONTEXT" \
    -f "${ROOT_DIR}/addons/ingress/nginx-values.yaml" \
    $NGINX_EXTRA_VALUES \
    --wait --timeout 15m
else
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx --create-namespace \
    --kube-context "$TARGET_CONTEXT" \
    -f "${ROOT_DIR}/addons/ingress/nginx-values.yaml" \
    --wait --timeout 15m
fi

helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  --kube-context "$TARGET_CONTEXT" \
  -f "${ROOT_DIR}/addons/observability/metrics-server-values.yaml" \
  --wait --timeout 10m

case "$CLOUD" in
  aws)
    [[ -n "$AUTOSCALER_ROLE_ARN" ]] || { echo "--autoscaler-role-arn is required for aws"; exit 1; }

    kctl apply -f "${ROOT_DIR}/addons/storage/eks-gp3-storageclass.yaml"

    cat > "${TMP_DIR}/cluster-autoscaler-values.yaml" <<YAML
cloudProvider: aws
fullnameOverride: cluster-autoscaler
autoDiscovery:
  clusterName: ${CLUSTER_NAME}
awsRegion: ${REGION}
rbac:
  create: true
  serviceAccount:
    create: true
    name: cluster-autoscaler
    annotations:
      eks.amazonaws.com/role-arn: ${AUTOSCALER_ROLE_ARN}
    automountServiceAccountToken: true
extraArgs:
  balance-similar-node-groups: true
  expander: least-waste
  skip-nodes-with-system-pods: false
  scale-down-utilization-threshold: 0.5
  scale-down-unneeded-time: 2m
  scale-down-delay-after-add: 2m
  stderrthreshold: info
image:
  tag: v1.34.0
resources:
  requests:
    cpu: 100m
    memory: 300Mi
  limits:
    cpu: 300m
    memory: 600Mi
YAML

    helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
      -n kube-system --kube-context "$TARGET_CONTEXT" -f "${TMP_DIR}/cluster-autoscaler-values.yaml" \
      --wait --timeout 10m

    # Ensure pods are recreated so fresh IRSA token/web identity env is projected.
    kctl -n kube-system rollout restart deployment/cluster-autoscaler >/dev/null
    kctl -n kube-system rollout status deployment/cluster-autoscaler --timeout=600s >/dev/null
    ;;
  gcp)
    kctl apply -f "${ROOT_DIR}/addons/storage/gke-pd-storageclass.yaml"
    ;;
  azure)
    kctl apply -f "${ROOT_DIR}/addons/storage/aks-disk-file-storageclasses.yaml"
    ;;
  *)
    echo "invalid cloud: $CLOUD"
    exit 1
    ;;
esac

kctl wait --for=condition=Available deployment/ingress-nginx-controller -n ingress-nginx --timeout=600s
kctl wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=600s

if [[ "$CLOUD" == "aws" ]]; then
  kctl wait --for=condition=Available deployment/cluster-autoscaler -n kube-system --timeout=600s
fi

echo "Bootstrap completed for ${CLUSTER_NAME} (${CLOUD})"
