#!/usr/bin/env bash
set -euo pipefail

# Managed Kubernetes does not accept arbitrary in-cluster KubeletConfiguration for existing nodes.
# This command routes to supported cloud-native controls.

CLOUD="${1:-}"
CLUSTER="${2:-}"
NODEPOOL="${3:-}"
MAX_PODS="${4:-110}"
ARG5="${5:-}"
ARG6="${6:-}"

if [[ -z "$CLOUD" || -z "$CLUSTER" || -z "$NODEPOOL" ]]; then
  echo "Usage: $0 <eks|gke|aks> <cluster> <nodepool> [max-pods] [provider args]"
  exit 1
fi

"$(cd "$(dirname "$0")" && pwd)/update-max-pods.sh" "$CLOUD" "$CLUSTER" "$NODEPOOL" "$MAX_PODS" "$ARG5" "$ARG6"
