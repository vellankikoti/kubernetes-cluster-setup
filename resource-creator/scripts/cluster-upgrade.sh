#!/usr/bin/env bash
set -euo pipefail

CLOUD=""
CLUSTER=""
REGION=""
VERSION=""
RESOURCE_GROUP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cloud)
      CLOUD="$2"
      shift 2
      ;;
    --cluster)
      CLUSTER="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --resource-group)
      RESOURCE_GROUP="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$CLOUD" || -z "$CLUSTER" || -z "$VERSION" ]]; then
  echo "Usage: $0 --cloud aws|gcp|azure --cluster <name> --version <k8s> [--region <region>] [--resource-group <rg>]"
  exit 1
fi

case "$CLOUD" in
  aws)
    [[ -n "$REGION" ]] || { echo "--region required for aws"; exit 1; }
    aws eks update-cluster-version --name "$CLUSTER" --kubernetes-version "$VERSION" --region "$REGION"
    for ng in on_demand spot; do
      aws eks update-nodegroup-version --cluster-name "$CLUSTER" --nodegroup-name "$ng" --kubernetes-version "$VERSION" --region "$REGION" || true
    done
    ;;
  gcp)
    [[ -n "$REGION" ]] || { echo "--region required for gcp"; exit 1; }
    gcloud container clusters upgrade "$CLUSTER" --region "$REGION" --master --cluster-version "$VERSION" --quiet
    for np in ondemand spot; do
      gcloud container node-pools upgrade "$np" --cluster "$CLUSTER" --region "$REGION" --cluster-version "$VERSION" --quiet || true
    done
    ;;
  azure)
    [[ -n "$RESOURCE_GROUP" ]] || { echo "--resource-group required for azure"; exit 1; }
    az aks upgrade --name "$CLUSTER" --resource-group "$RESOURCE_GROUP" --kubernetes-version "$VERSION" --control-plane-only --yes
    for np in system spot; do
      az aks nodepool upgrade --cluster-name "$CLUSTER" --resource-group "$RESOURCE_GROUP" --name "$np" --kubernetes-version "$VERSION" --yes || true
    done
    ;;
  *)
    echo "invalid cloud: $CLOUD"
    exit 1
    ;;
esac

kubectl get nodes -o wide
kubectl -n kube-system get pods
