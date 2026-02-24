#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-}"
if [[ -z "$ENV_NAME" ]]; then
  echo "Usage: $0 <dev|qa|staging|prod>"
  exit 1
fi

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/environments/${ENV_NAME}.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE"
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

required=(
  ENV AWS_REGION GCP_REGION AZURE_REGION GCP_PROJECT_ID AZURE_SUBSCRIPTION_ID
  BASE_DOMAIN ARGOCD_HOST DASHBOARD_HOST APP_HOST AUTH_ISSUER ROUTE53_DOMAIN_FILTER
  EFS_FILESYSTEM_ID EKS_OIDC_PROVIDER AWS_ACCOUNT_ID CLUSTER_AUTOSCALER_NAME AKS_RESOURCE_GROUP
)

for v in "${required[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "Missing required variable: $v"
    exit 1
  fi
done

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cat > "${ROOT_DIR}/terraform/eks/env/${ENV}.tfvars" <<TFVARS
region          = "${AWS_REGION}"
cluster_version = "1.34"
environments    = ["${ENV}"]
TFVARS

cat > "${ROOT_DIR}/terraform/gke/env/${ENV}.tfvars" <<TFVARS
project_id      = "${GCP_PROJECT_ID}"
region          = "${GCP_REGION}"
cluster_version = "1.34"
environments    = ["${ENV}"]
TFVARS

cat > "${ROOT_DIR}/terraform/aks/env/${ENV}.tfvars" <<TFVARS
subscription_id = "${AZURE_SUBSCRIPTION_ID}"
region          = "${AZURE_REGION}"
cluster_version = "1.34"
environments    = ["${ENV}"]
TFVARS

OVR_DIR="${ROOT_DIR}/addons/overrides/${ENV}"
mkdir -p "$OVR_DIR"

cat > "${OVR_DIR}/external-dns-values.yaml" <<YAML
policy: sync
txtOwnerId: multi-cloud-platform-${ENV}
domainFilters:
  - ${ROUTE53_DOMAIN_FILTER}
YAML

cat > "${OVR_DIR}/argocd-values.yaml" <<YAML
server:
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - ${ARGOCD_HOST}
    tls:
      - hosts:
          - ${ARGOCD_HOST}
        secretName: argocd-tls
  config:
    url: https://${ARGOCD_HOST}
    oidc.config: |
      name: SSO
      issuer: ${AUTH_ISSUER}
      clientID: argocd
      clientSecret: \$oidc.clientSecret
      requestedScopes: ["openid", "profile", "email", "groups"]
YAML

cat > "${OVR_DIR}/dashboard-values.yaml" <<YAML
app:
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - ${DASHBOARD_HOST}
    tls:
      enabled: true
      secretName: dashboard-tls
auth:
  mode: token
metricsScraper:
  enabled: true
kong:
  enabled: false
YAML

cat > "${OVR_DIR}/cluster-autoscaler-values.yaml" <<YAML
autoDiscovery:
  clusterName: ${CLUSTER_AUTOSCALER_NAME}
awsRegion: ${AWS_REGION}
rbac:
  create: true
extraArgs:
  balance-similar-node-groups: true
  expander: least-waste
  skip-nodes-with-system-pods: false
  scale-down-utilization-threshold: 0.5
  scale-down-unneeded-time: 10m
resources:
  requests:
    cpu: 100m
    memory: 512Mi
  limits:
    cpu: 300m
    memory: 1Gi
YAML

cat > "${OVR_DIR}/nginx-values.yaml" <<YAML
controller:
  service:
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-scheme: internal
      service.beta.kubernetes.io/aws-load-balancer-type: nlb
YAML

cat > "${OVR_DIR}/eks-efs-csi-values.yaml" <<YAML
controller:
  serviceAccount:
    create: false
    name: efs-csi-controller-sa
storageClasses:
  - name: efs-sc
    parameters:
      provisioningMode: efs-ap
      fileSystemId: ${EFS_FILESYSTEM_ID}
      directoryPerms: "700"
    reclaimPolicy: Retain
    volumeBindingMode: Immediate
YAML

cat > "${OVR_DIR}/irsa-external-dns-trust-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${EKS_OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${EKS_OIDC_PROVIDER}:sub": "system:serviceaccount:kube-system:external-dns",
          "${EKS_OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
JSON

cat > "${ROOT_DIR}/common-resources/ingress-template.${ENV}.yaml" <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${APP_HOST}
      secretName: app-${ENV}-tls
  rules:
    - host: ${APP_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-service
                port:
                  number: 80
YAML

echo "Rendered environment '${ENV}' successfully"
echo "Generated tfvars in terraform/{eks,gke,aks}/env/${ENV}.tfvars"
echo "Generated addon overrides in addons/overrides/${ENV}/"
