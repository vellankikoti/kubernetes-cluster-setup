#!/usr/bin/env bash
set -euo pipefail

CLOUD=""
REGION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cloud)
      CLOUD="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$CLOUD" || -z "$REGION" ]]; then
  echo "Usage: $0 --cloud aws|gcp|azure --region <region>"
  exit 1
fi

for c in terraform kubectl helm; do
  command -v "$c" >/dev/null 2>&1 || { echo "missing required command: $c"; exit 1; }
done

case "$CLOUD" in
  aws)
    command -v aws >/dev/null 2>&1 || { echo "missing required command: aws"; exit 1; }
    aws sts get-caller-identity >/dev/null
    aws ec2 describe-availability-zones --region "$REGION" >/dev/null
    ;;
  gcp)
    command -v gcloud >/dev/null 2>&1 || { echo "missing required command: gcloud"; exit 1; }
    PROJECT_ID="$(gcloud config get-value project 2>/dev/null | tr -d '\r')"
    [[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || { echo "gcloud project is not set"; exit 1; }
    gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q . || { echo "no active gcloud account"; exit 1; }
    gcloud compute regions describe "$REGION" --project "$PROJECT_ID" >/dev/null
    ;;
  azure)
    command -v az >/dev/null 2>&1 || { echo "missing required command: az"; exit 1; }
    az account show >/dev/null
    az account list-locations --query "[?name=='${REGION}'].name" -o tsv | grep -q "^${REGION}$" || { echo "invalid azure region: ${REGION}"; exit 1; }
    ;;
  *)
    echo "invalid cloud: $CLOUD"
    exit 1
    ;;
esac

echo "Preflight OK for cloud=${CLOUD} region=${REGION}"
