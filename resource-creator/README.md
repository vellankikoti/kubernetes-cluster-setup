# Kubernetes Cluster Factory

This repository provisions and validates Kubernetes clusters on EKS, GKE, and AKS using one command.

## 1. Prerequisites

Required local tools:
- Terraform `>= 1.7` (tested with `1.7.x` and newer)
- AWS CLI v2
- Google Cloud SDK (`gcloud`)
- Azure CLI (`az`)
- kubectl `>= 1.29`
- Helm `>= 3.14`

Required authentication state:
- AWS: configured profile with EKS/VPC/IAM permissions
- GCP: active project and account with GKE/Compute/IAM permissions
- Azure: active subscription with AKS/VNet/Monitor permissions

Verification commands:

```bash
terraform version
aws --version
gcloud --version
az version
kubectl version --client
helm version

aws sts get-caller-identity
gcloud config get-value project
gcloud auth list --filter=status:ACTIVE
az account show
```

Minimum permission scope by cloud:
- AWS: EKS, EC2, IAM, KMS, CloudWatch Logs, VPC networking APIs
- GCP: container, compute, iam, logging, monitoring API + project IAM rights
- Azure: AKS, Virtual Network, Log Analytics, Managed Identity rights

## 2. One-Command Cluster Creation

AWS:

```bash
cd resource-creator
./scripts/create-cluster.sh --cloud aws --name mycluster --env dev --region us-east-1
```

GCP:

```bash
cd resource-creator
./scripts/create-cluster.sh --cloud gcp --name mycluster --env dev --region us-central1
```

Azure:

```bash
cd resource-creator
./scripts/create-cluster.sh --cloud azure --name mycluster --env dev --region eastus
```

Flags:
- `--cloud`: target platform (`aws|gcp|azure`)
- `--name`: logical cluster family name used to derive deterministic resource names
- `--env`: environment (`dev|qa|staging|prod`)
- `--region`: cloud region for network + cluster resources

## 3. What Gets Created Automatically

Per cloud behavior from Terraform + scripts:

AWS (`terraform/eks` + scripts)
- Networking:
  - VPC
  - 3 private subnets + 3 public subnets
  - NAT gateway (single NAT for non-prod, multi-NAT behavior for prod)
- Cluster:
  - EKS managed control plane
  - Kubernetes `1.34`
  - managed nodegroups: `on_demand` + `spot`
  - node autoscaling via group min/max/desired settings
  - managed nodegroup rolling update config (`max_unavailable_percentage = 25`)
  - secrets encryption via KMS
- Addons:
  - EKS managed addons: CoreDNS, kube-proxy, VPC CNI, EBS CSI, EFS CSI
  - Helm: NGINX ingress, metrics-server, cluster-autoscaler
  - StorageClass default: `gp3-encrypted`

GCP (`terraform/gke` + scripts)
- Networking:
  - custom VPC + subnet
  - secondary CIDRs for pods/services
  - Cloud Router + Cloud NAT
- Cluster:
  - regional GKE cluster
  - Kubernetes `1.34`
  - private nodes enabled
  - node pools: `ondemand` + `spot`
  - autoscaling on both pools
  - node upgrade surge config (`max_surge=1`, `max_unavailable=0`)
- Addons:
  - Helm: NGINX ingress, metrics-server
  - StorageClass default: `pd-balanced-encrypted`

Azure (`terraform/aks` + scripts)
- Networking:
  - resource group
  - VNet + subnet
- Cluster:
  - private AKS cluster
  - Kubernetes `1.34`
  - system node pool + spot node pool
  - autoscaling and surge update settings (`max_surge="33%"`)
  - OIDC issuer + workload identity enabled
- Addons:
  - Helm: NGINX ingress, metrics-server
  - StorageClass default: `managed-csi-premium`

Common resources applied for all clusters:
- namespaces
- priority class
- default network policies
- resource quotas
- limit ranges
- pod disruption budgets

Files:
- `common-resources/namespaces.yaml`
- `common-resources/network-policies.yaml`
- `common-resources/resource-quotas.yaml`
- `common-resources/limit-ranges.yaml`
- `common-resources/pod-disruption-budgets.yaml`

Auto-generated during `create-cluster.sh` run:
- runtime Terraform var file in a temporary directory (`mktemp -d`)
- runtime cloud-specific cluster names (deterministic from `--name`, `--env`, and account/project/subscription hash)
- local kubeconfig context for the created cluster
- runtime autoscaler values for EKS
- validation namespace and test resources (`validation` namespace, PVC, workload, ingress)

## 4. Default Configuration Decisions (And Why)

- Managed control plane: selected to reduce operational burden and control plane failure handling.
- Multi-pool worker strategy (`on_demand` + `spot`): balances availability and cost.
- Private node posture for GKE/AKS: reduces direct public exposure of worker nodes.
- Encryption at rest (EKS KMS): protects Kubernetes secrets.
- NGINX ingress controller: consistent ingress behavior across clouds.
- Metrics server installation: required for resource metrics and autoscaler validation.
- Cloud-native CSI defaults:
  - EKS `gp3-encrypted`
  - GKE `pd-balanced-encrypted`
  - AKS `managed-csi-premium`

Trade-offs:
- Spot capacity lowers cost but increases eviction risk.
- Private networking improves security but increases network design complexity.
- Conservative upgrade surge settings reduce disruption but may lengthen upgrade time.

## 5. How To Modify Configuration Safely

Change node instance/VM type:
- AWS: `terraform/eks/main.tf` under `eks_managed_node_groups`
- GCP: `terraform/gke/main.tf` under `google_container_node_pool.*.node_config.machine_type`
- Azure: `terraform/aks/main.tf` under `default_node_pool.vm_size` and `azurerm_kubernetes_cluster_node_pool.spot.vm_size`

Change min/max nodes:
- AWS: `terraform/eks/main.tf` `min_size`, `max_size`, `desired_size`
- GCP: `terraform/gke/main.tf` node pool `autoscaling` blocks
- Azure: `terraform/aks/main.tf` node pool `min_count`, `max_count`

Change Kubernetes version:
- `cluster_version` in:
  - `terraform/eks/variables.tf`
  - `terraform/gke/variables.tf`
  - `terraform/aks/variables.tf`
- Runtime override path is generated by `scripts/create-cluster.sh` in temporary tfvars.

Change ingress controller config:
- Base values: `addons/ingress/nginx-values.yaml`
- EKS overlay generated at runtime in temporary values from `scripts/bootstrap.sh`

Add a new addon:
1. Add Helm values/manifests under `addons/`
2. Install it inside `scripts/bootstrap.sh`
3. Add health check to `scripts/validation.sh`

Disable autoscaler:
- AWS only in current automation:
  - remove/comment cluster-autoscaler install section in `scripts/bootstrap.sh`
  - disable autoscaler validation section in `scripts/validation.sh`

Change CIDR ranges:
- AWS: `terraform/eks/main.tf` `locals.env_config[*].cidr`
- GCP: `terraform/gke/main.tf` `locals.env_config[*].cidr`
- Azure: `terraform/aks/main.tf` `locals.env_config[*].cidr`

Tighten GKE master CIDR:
- `scripts/create-cluster.sh` currently sets:
  - `master_authorized_cidrs = ["0.0.0.0/0"]`
- Replace with your office/VPN CIDR in `create-cluster.sh` template block for GCP.
- Also adjust default in `terraform/gke/variables.tf` (`master_authorized_cidrs`).

What should NOT be modified:
- `scripts/create-cluster.sh` naming hash logic, unless you also update `destroy-cluster.sh` to match exactly.
- Node pool logical names (`on_demand`, `spot`, `ondemand`, `system`), unless you update scaling/upgrade scripts and validation accordingly.
- Validation workload resource requests, unless you understand autoscaler test behavior impact.

## 6. Environment Strategy

- `dev`, `qa`, `staging`, `prod` are inputs to naming and Terraform env selection.
- Collision avoidance:
  - Name suffix derives from account/project/subscription identity hash.
  - Resulting cluster names are deterministic and unique per cloud account context.
- Isolation:
  - Each environment resolves to distinct network CIDR blocks in Terraform locals.
  - Separate cluster per environment; no shared control plane.
- `dev` vs `prod` defaults:
  - Lower min/desired sizing in non-prod.
  - Higher floor and max values in prod.

## 7. Upgrade Process

Command:

```bash
./scripts/cluster-upgrade.sh --cloud aws --cluster <cluster-name> --region us-east-1 --version 1.34
./scripts/cluster-upgrade.sh --cloud gcp --cluster <cluster-name> --region us-central1 --version 1.34
./scripts/cluster-upgrade.sh --cloud azure --cluster <cluster-name> --resource-group <rg-name> --version 1.34
```

What happens:
- control plane upgrade first
- node pools/nodegroups upgraded next
- rolling behavior uses configured surge/unavailable settings in Terraform

Verify upgrade success:

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods
./scripts/validation.sh --cloud aws --cluster <cluster-name> --region us-east-1
```

## 8. Validation Process

Validation script:

```bash
./scripts/validation.sh --cloud aws --cluster <cluster-name> --region us-east-1
```

Checks performed:
- cluster reachable (`kubectl get nodes`)
- all namespaces pod listing (`kubectl get pods -A`)
- PVC bind success
- nginx deployment rollout
- ingress controller endpoint allocation
- HTTP 200 through ingress
- metrics-server availability (`kubectl top nodes`)
- autoscaler scale up/down behavior
- default storage class presence

Failure semantics:
- Any failed check exits non-zero immediately.
- Cluster is not considered usable for production workloads until validation passes.

Debug approach:
- ingress: `kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide`
- autoscaler: `kubectl -n kube-system get deploy cluster-autoscaler` (EKS)
- storage: `kubectl get sc` and `kubectl -n validation describe pvc pvc-test`

## 9. Production Hardening Checklist

☐ Restrict API server CIDR (especially GKE `master_authorized_cidrs`)  
☐ Enable control plane logging and retention  
☐ Confirm encryption settings for secrets and volumes  
☐ Review IAM/Role assignments and least privilege  
☐ Define backup strategy (etcd snapshots/Velero/PV backups)  
☐ Enable and retain audit logs centrally  
☐ Configure policy guardrails (OPA/Gatekeeper/Kyverno)  
☐ Enforce image provenance and vulnerability scanning  
☐ Add remote Terraform state + locking for team use  

## 10. Teardown Process

```bash
./scripts/destroy-cluster.sh --cloud aws --name mycluster --env dev --region us-east-1
./scripts/destroy-cluster.sh --cloud gcp --name mycluster --env dev --region us-central1
./scripts/destroy-cluster.sh --cloud azure --name mycluster --env dev --region eastus
```

What gets removed:
- Terraform-managed networking and cluster resources for the selected cloud/env/name combination.

What does not get removed automatically:
- Any manually created resources outside Terraform state.
- External DNS records not managed by Terraform.
- External observability backends, registries, or IAM assets created outside this factory.

## 11. Known Limitations

- Current one-command flow uses local Terraform state (`terraform init -backend=false`) for first-run simplicity.
- EKS cluster-autoscaler is automated; GKE/AKS rely on native autoscaling behavior in this workflow.
- GKE master authorized CIDR defaults are permissive in script-generated runtime vars unless tightened.
- Full addon suite in repository is larger than the minimal one-command bootstrap path; only core addons are installed by default.
- No automatic backup stack deployment is included in `create-cluster.sh`.

## Example Execution Logs

AWS create:

```text
$ ./scripts/create-cluster.sh --cloud aws --name mycluster --env dev --region us-east-1
Preflight OK for cloud=aws region=us-east-1
...
Bootstrap completed for mycluster-aws-a1b2c3-dev-eks (aws)
Validation succeeded for mycluster-aws-a1b2c3-dev-eks (aws)
INGRESS_ENDPOINT=a1b2c3d4e5f6.us-east-1.elb.amazonaws.com
DEFAULT_STORAGE_CLASS=gp3-encrypted

✅ Cluster name: mycluster-aws-a1b2c3-dev-eks
✅ Region: us-east-1
✅ Kubernetes version: v1.34.x
✅ Nodegroup size: 3
✅ kubectl get nodes output:
<node-list>
✅ Ingress endpoint: a1b2c3d4e5f6.us-east-1.elb.amazonaws.com
✅ Autoscaler status: 1
✅ Storage class status: gp3-encrypted
```

GCP create:

```text
$ ./scripts/create-cluster.sh --cloud gcp --name mycluster --env qa --region us-central1
Preflight OK for cloud=gcp region=us-central1
...
Bootstrap completed for mycluster-gcp-7f9a21-qa-gke (gcp)
Validation succeeded for mycluster-gcp-7f9a21-qa-gke (gcp)
INGRESS_ENDPOINT=34.120.10.20
DEFAULT_STORAGE_CLASS=pd-balanced-encrypted
...
✅ Autoscaler status: native
```

Azure create:

```text
$ ./scripts/create-cluster.sh --cloud azure --name mycluster --env staging --region eastus
Preflight OK for cloud=azure region=eastus
...
Bootstrap completed for mycluster-az-3c0f8a-staging-aks (azure)
Validation succeeded for mycluster-az-3c0f8a-staging-aks (azure)
INGRESS_ENDPOINT=20.81.44.100
DEFAULT_STORAGE_CLASS=managed-csi-premium
...
✅ Autoscaler status: native
```
