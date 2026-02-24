#!/usr/bin/env bash
set -euo pipefail

CLUSTER="${1:-}"
REGION="${2:-us-east-1}"

if [[ -z "$CLUSTER" ]]; then
  echo "Usage: $0 <cluster-name> [region]"
  exit 1
fi

aws eks update-addon \
  --cluster-name "$CLUSTER" \
  --addon-name vpc-cni \
  --region "$REGION" \
  --configuration-values '{"env":{"ENABLE_PREFIX_DELEGATION":"true","WARM_PREFIX_TARGET":"1"}}' \
  --resolve-conflicts OVERWRITE

echo "Prefix delegation enabled for cluster $CLUSTER"
