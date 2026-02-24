#!/usr/bin/env bash
set -euo pipefail

CLOUD=""
CLUSTER_NAME=""
REGION=""
FULL_VALIDATION="false"
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
    --full-validation)
      FULL_VALIDATION="true"
      shift 1
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

if [[ -z "$CLOUD" || -z "$CLUSTER_NAME" || -z "$REGION" ]]; then
  echo "Usage: $0 --cloud aws|gcp|azure --cluster <name> --region <region> [--full-validation] [--public-api]"
  exit 1
fi

command -v curl >/dev/null 2>&1 || { echo "missing command: curl"; exit 1; }
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT_DIR}/scripts/backend-lib.sh"
PREV_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
TARGET_CONTEXT=""

AWS_PUBLIC_API_TEMP_ENABLED="false"
cleanup() {
  if [[ "$CLOUD" == "aws" && "$PUBLIC_API" == "true" && "$AWS_PUBLIC_API_TEMP_ENABLED" == "true" ]]; then
    # Best practice: public endpoint is temporary for validation only.
    restore_eks_private_only "$CLUSTER_NAME" "$REGION" || true
  fi
  if [[ -n "$PREV_CONTEXT" ]]; then
    kubectl config use-context "$PREV_CONTEXT" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "$CLOUD" == "aws" ]] && ! kube_api_reachable; then
  command -v aws >/dev/null 2>&1 || { echo "missing command: aws"; exit 1; }
  wait_for_eks_active "$CLUSTER_NAME" "$REGION"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias "$CLUSTER_NAME" >/dev/null
fi

TARGET_CONTEXT="$(resolve_kube_context "$CLUSTER_NAME" || true)"
if [[ -z "$TARGET_CONTEXT" ]]; then
  echo "unable to resolve kube context for cluster: $CLUSTER_NAME"
  exit 1
fi

kctl() {
  kubectl --context "$TARGET_CONTEXT" "$@"
}

if ! kctl --request-timeout=10s get --raw='/readyz' >/dev/null 2>&1; then
  if [[ "$CLOUD" == "aws" && "$PUBLIC_API" == "true" ]]; then
    CALLER_IP="$(get_public_ip)"
    ensure_eks_public_api_access "$CLUSTER_NAME" "$REGION" "${CALLER_IP}/32"
    AWS_PUBLIC_API_TEMP_ENABLED="true"
    if ! wait_for_kube_api 36 10 || ! kctl --request-timeout=15s get --raw='/readyz' >/dev/null 2>&1; then
      echo "EKS API still unreachable after enabling temporary public endpoint."
      echo "Likely DNS propagation or network egress restriction from this machine."
      echo "Retry in 2-3 minutes, or run from a network with direct internet egress."
      exit 1
    fi
  else
    echo "Kubernetes API is unreachable from this host."
    echo "For private clusters, use VPN/bastion/private runner."
    if [[ "$CLOUD" == "aws" ]]; then
      echo "For learning/demo only, rerun validation with --public-api to use temporary CIDR-restricted public endpoint."
    fi
    exit 1
  fi
fi

kctl --request-timeout=20s get nodes >/dev/null

NON_RUNNING_PODS="$(kctl --request-timeout=20s get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null || true)"
if [[ -n "$NON_RUNNING_PODS" && "$NON_RUNNING_PODS" != "No resources found" ]]; then
  echo "non-running pods detected"
  echo "$NON_RUNNING_PODS"
  exit 1
fi

TEST_NS="validation"
kctl create ns "$TEST_NS" --dry-run=client -o yaml | kctl apply -f - >/dev/null

cat <<'YAML' | kctl apply -n "$TEST_NS" -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-test
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
YAML

cat <<'YAML' | kctl apply -n "$TEST_NS" -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: pvc-consumer
spec:
  restartPolicy: Never
  containers:
    - name: pause
      image: registry.k8s.io/pause:3.9
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: pvc-test
YAML

kctl wait -n "$TEST_NS" --for=jsonpath='{.status.phase}'=Bound pvc/pvc-test --timeout=300s >/dev/null
kctl wait -n "$TEST_NS" --for=condition=Ready pod/pvc-consumer --timeout=300s >/dev/null

cat <<'YAML' | kctl apply -n "$TEST_NS" -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 300m
              memory: 256Mi
YAML

kctl rollout status -n "$TEST_NS" deployment/web --timeout=300s >/dev/null
kctl expose deployment web -n "$TEST_NS" --port=80 --target-port=80 --type=ClusterIP --dry-run=client -o yaml | kctl apply -f - >/dev/null

cat <<'YAML' | kctl apply -n "$TEST_NS" -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
spec:
  ingressClassName: nginx
  rules:
    - host: web.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 80
YAML

INGRESS_ADDR=""
for _ in $(seq 1 32); do
  INGRESS_ADDR="$(kctl --request-timeout=15s -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$INGRESS_ADDR" ]] && break
  sleep 10
done
[[ -n "$INGRESS_ADDR" ]] || { echo "ingress endpoint not assigned"; exit 1; }

HTTP_CODE=""
for _ in $(seq 1 18); do
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: web.local' "http://${INGRESS_ADDR}/" || true)"
  [[ "$HTTP_CODE" == "200" ]] && break
  sleep 5
done
[[ "$HTTP_CODE" == "200" ]] || { echo "ingress not reachable, status=${HTTP_CODE}"; exit 1; }

kctl --request-timeout=20s top nodes >/dev/null

DEFAULT_SC="$(kctl --request-timeout=20s get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' | head -n1)"
[[ -n "$DEFAULT_SC" ]] || { echo "no default storage class"; exit 1; }

if [[ "$CLOUD" == "aws" ]]; then
  kctl -n kube-system get deploy cluster-autoscaler >/dev/null
  ROLE_ARN="$(kctl -n kube-system get sa cluster-autoscaler -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')"
  [[ -n "$ROLE_ARN" ]] || { echo "cluster-autoscaler serviceaccount missing IRSA annotation"; exit 1; }

  if kctl -n kube-system logs deploy/cluster-autoscaler --tail=200 2>/dev/null | grep -Eqi 'AccessDenied|UnauthorizedOperation'; then
    echo "cluster-autoscaler IAM access appears denied"
    exit 1
  fi
fi

if [[ "$FULL_VALIDATION" == "true" ]]; then
  INITIAL_NODES="$(kctl get nodes --no-headers | wc -l | tr -d ' ')"

  cat <<'YAML' | kctl apply -n "$TEST_NS" -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: autoscaler-burst
spec:
  replicas: 20
  selector:
    matchLabels:
      app: autoscaler-burst
  template:
    metadata:
      labels:
        app: autoscaler-burst
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: "1000m"
              memory: "256Mi"
            limits:
              cpu: "1000m"
              memory: "256Mi"
YAML

  SCALED_UP="false"
  for _ in $(seq 1 24); do
    CURRENT_NODES="$(kctl get nodes --no-headers | wc -l | tr -d ' ')"
    if [[ "$CURRENT_NODES" -gt "$INITIAL_NODES" ]]; then
      SCALED_UP="true"
      break
    fi
    sleep 10
  done
  [[ "$SCALED_UP" == "true" ]] || { echo "autoscaler scale-up failed"; exit 1; }

  kctl scale deployment autoscaler-burst -n "$TEST_NS" --replicas=0 >/dev/null

  SCALED_DOWN="false"
  for _ in $(seq 1 48); do
    CURRENT_NODES="$(kctl get nodes --no-headers | wc -l | tr -d ' ')"
    if [[ "$CURRENT_NODES" -le "$INITIAL_NODES" ]]; then
      SCALED_DOWN="true"
      break
    fi
    sleep 10
  done
  [[ "$SCALED_DOWN" == "true" ]] || { echo "autoscaler scale-down failed"; exit 1; }
fi

kctl delete ns "$TEST_NS" --wait=false >/dev/null 2>&1 || true

echo "Validation succeeded for ${CLUSTER_NAME} (${CLOUD})"
echo "INGRESS_ENDPOINT=${INGRESS_ADDR}"
echo "DEFAULT_STORAGE_CLASS=${DEFAULT_SC}"
echo "VALIDATION_MODE=$([[ "$FULL_VALIDATION" == "true" ]] && echo full || echo smoke)"
echo "KUBE_CONTEXT=${TARGET_CONTEXT}"
