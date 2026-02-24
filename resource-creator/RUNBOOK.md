# Runbook

## Troubleshooting

### Preflight fails
- Verify tools: `aws|gcloud|az`, `terraform`, `kubectl`, `helm`.
- Verify auth:
  - AWS: `aws sts get-caller-identity`
  - GCP: `gcloud config get-value project` and active account
  - Azure: `az account show`

### Terraform apply fails
- Re-run same `create-cluster.sh` command; workflow is idempotent.
- If state is partial, run matching `destroy-cluster.sh` then re-run create.

### Ingress endpoint not assigned
- Check `ingress-nginx-controller` service:
  - `kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide`
- Check cloud load balancer quota limits.

### Autoscaler validation fails
- Confirm pending pods exist:
  - `kubectl -n validation get pods`
- EKS only: confirm deployment exists:
  - `kubectl -n kube-system get deploy cluster-autoscaler`
- Check node group/pool autoscaling bounds in Terraform.

### PVC bind fails
- Verify default storage class:
  - `kubectl get sc`
- Verify CSI driver and storageclass for cloud.

## Failure Scenarios

### Node failure
- Delete a node and verify workload reschedule:
  - `kubectl delete node <node>`
  - `kubectl get pods -A -o wide`

### Spot interruption
- Ensure workloads with tolerations move/restart on on-demand pools.

### AZ failure
- Verify multi-AZ subnets and zonal pools/nodegroups are active.

### Control plane upgrade
- Use:
  - `./scripts/cluster-upgrade.sh --cloud aws --cluster <name> --region <region> --version 1.34`
  - `./scripts/cluster-upgrade.sh --cloud gcp --cluster <name> --region <region> --version 1.34`
  - `./scripts/cluster-upgrade.sh --cloud azure --cluster <name> --resource-group <rg> --version 1.34`

### Storage expansion
- Patch PVC request and verify resize.

### Cert/IAM rotation
- Run:
  - `./scripts/rotate-certificates.sh <cloud> <cluster> [region_or_rg]`

## Upgrade Process

1. Run `destroy-cluster.sh` in non-prod for rollback rehearsal.
2. Run `cluster-upgrade.sh` in `dev`, then `qa`, `staging`, `prod`.
3. Re-run `validation.sh` after each upgrade.
4. Promote only on full validation pass.
