"""Shared library for Kubernetes cluster creation and destruction.

Equivalent to scripts/backend-lib.sh — provides naming, backend preparation,
quota checks, and cloud-specific resource cleanup functions.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------

ROOT_DIR = Path(__file__).resolve().parent.parent


def run(cmd: list[str], *, check: bool = True, capture: bool = True,
        timeout: int = 300, quiet: bool = False) -> subprocess.CompletedProcess:
    """Run a shell command and return the result."""
    if not quiet:
        print(f"  $ {' '.join(cmd)}", file=sys.stderr)
    return subprocess.run(
        cmd, check=check, capture_output=capture, text=True, timeout=timeout,
    )


def run_output(cmd: list[str], **kwargs) -> str:
    """Run a command and return stripped stdout."""
    return run(cmd, **kwargs).stdout.strip()


def sanitize_name(name: str) -> str:
    name = name.lower()
    name = re.sub(r"[^a-z0-9-]", "-", name)
    name = re.sub(r"-+", "-", name)
    return name.strip("-")


def hash8(value: str) -> str:
    return hashlib.sha1(value.encode()).hexdigest()[:8]


def get_public_ip() -> str:
    for url in ("https://checkip.amazonaws.com", "https://ifconfig.me"):
        try:
            ip = run_output(["curl", "-fsS", url], quiet=True).strip()
            if re.match(r"^(\d{1,3}\.){3}\d{1,3}$", ip):
                return ip
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            continue
    raise RuntimeError("Unable to detect caller public IPv4")


def require_cmd(name: str) -> None:
    if not subprocess.run(["which", name], capture_output=True).returncode == 0:
        raise RuntimeError(f"Missing required command: {name}")


# ---------------------------------------------------------------------------
# Cluster naming (deterministic, matches shell scripts exactly)
# ---------------------------------------------------------------------------

def derive_cluster_info(cloud: str, name: str, env_name: str,
                        region: str) -> dict:
    """Derive base_name, cluster_name from inputs — mirrors shell logic."""
    if cloud == "aws":
        account_id = run_output(
            ["aws", "sts", "get-caller-identity", "--query", "Account",
             "--output", "text"])
        suffix = account_id[-6:]
        suffix_tag = f"-{env_name}-eks"
        if name.endswith(suffix_tag):
            cluster_name = sanitize_name(name)
            base_name = cluster_name.removesuffix(suffix_tag)
        else:
            base_name = sanitize_name(f"{name}-aws-{suffix}")
            cluster_name = f"{base_name}-{env_name}-eks"
        return {"base_name": base_name, "cluster_name": cluster_name,
                "account_id": account_id}

    elif cloud == "gcp":
        project_id = run_output(
            ["gcloud", "config", "get-value", "project"]).strip()
        if not project_id or project_id == "(unset)":
            raise RuntimeError("gcloud project is not set")
        proj_hash = hash8(project_id)
        suffix_tag = f"-{env_name}-gke"
        if name.endswith(suffix_tag):
            cluster_name = sanitize_name(name)
            base_name = cluster_name.removesuffix(suffix_tag)
        else:
            base_name = sanitize_name(f"{name}-gcp-{proj_hash}")
            cluster_name = f"{base_name}-{env_name}-gke"
        return {"base_name": base_name, "cluster_name": cluster_name,
                "project_id": project_id}

    elif cloud == "azure":
        sub_id = run_output(
            ["az", "account", "show", "--query", "id", "-o", "tsv"])
        sub_hash = hash8(sub_id)
        suffix_tag = f"-{env_name}-aks"
        if name.endswith(suffix_tag):
            cluster_name = sanitize_name(name)
            base_name = cluster_name.removesuffix(suffix_tag)
        else:
            base_name = sanitize_name(f"{name}-az-{sub_hash}")
            cluster_name = f"{base_name}-{env_name}-aks"
        return {"base_name": base_name, "cluster_name": cluster_name,
                "subscription_id": sub_id}

    raise ValueError(f"Invalid cloud: {cloud}")


# ---------------------------------------------------------------------------
# Terraform variable and backend file generation
# ---------------------------------------------------------------------------

def write_tfvars(path: str, cloud: str, info: dict, env_name: str,
                 region: str, *, public_api: bool = False) -> None:
    lines = []
    if cloud == "aws":
        lines = [
            f'region                         = "{region}"',
            f'base_name                      = "{info["base_name"]}"',
            f'cluster_version                = "1.34"',
            f'environments                   = ["{env_name}"]',
            f'cluster_endpoint_public_access = {"true" if public_api else "false"}',
        ]
    elif cloud == "gcp":
        caller_ip = get_public_ip()
        private_endpoint = "false" if public_api else "true"
        lines = [
            f'project_id                = "{info["project_id"]}"',
            f'region                    = "{region}"',
            f'base_name                 = "{info["base_name"]}"',
            f'cluster_version           = "1.34"',
            f'environments              = ["{env_name}"]',
            f'master_authorized_cidrs   = ["{caller_ip}/32"]',
            f'enable_private_endpoint   = {private_endpoint}',
        ]
    elif cloud == "azure":
        lines = [
            f'subscription_id = "{info["subscription_id"]}"',
            f'region          = "{region}"',
            f'base_name       = "{info["base_name"]}"',
            f'cluster_version = "1.34"',
            f'environments    = ["{env_name}"]',
        ]
    Path(path).write_text("\n".join(lines) + "\n")


def prepare_aws_backend(cluster_name: str, env_name: str, region: str,
                        backend_file: str) -> None:
    account_id = run_output(
        ["aws", "sts", "get-caller-identity", "--query", "Account",
         "--output", "text"])
    bucket = f"rc-tfstate-{account_id}-{region}"
    table = "rc-tf-locks"
    key = f"aws/{cluster_name}/{env_name}/{region}/terraform.tfstate"

    # Create bucket if needed
    head = run(["aws", "s3api", "head-bucket", "--bucket", bucket],
               check=False, quiet=True)
    if head.returncode != 0:
        create_cmd = ["aws", "s3api", "create-bucket", "--bucket", bucket]
        if region != "us-east-1":
            create_cmd += ["--create-bucket-configuration",
                           f"LocationConstraint={region}"]
        run(create_cmd, quiet=True)

    run(["aws", "s3api", "put-bucket-versioning", "--bucket", bucket,
         "--versioning-configuration", "Status=Enabled"], quiet=True)
    run(["aws", "s3api", "put-bucket-encryption", "--bucket", bucket,
         "--server-side-encryption-configuration",
         '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'],
        quiet=True)

    # DynamoDB lock table
    desc = run(["aws", "dynamodb", "describe-table", "--table-name", table,
                "--region", region], check=False, quiet=True)
    if desc.returncode != 0:
        run(["aws", "dynamodb", "create-table", "--table-name", table,
             "--attribute-definitions", "AttributeName=LockID,AttributeType=S",
             "--key-schema", "AttributeName=LockID,KeyType=HASH",
             "--billing-mode", "PAY_PER_REQUEST", "--region", region],
            quiet=True)
        run(["aws", "dynamodb", "wait", "table-exists", "--table-name", table,
             "--region", region], quiet=True)

    Path(backend_file).write_text(
        f'bucket         = "{bucket}"\n'
        f'key            = "{key}"\n'
        f'region         = "{region}"\n'
        f'encrypt        = true\n'
        f'dynamodb_table = "{table}"\n')


def prepare_gcp_backend(cluster_name: str, env_name: str, region: str,
                        project_id: str, backend_file: str) -> None:
    bucket = sanitize_name(f"rc-tfstate-{project_id}")
    desc = run(["gcloud", "storage", "buckets", "describe",
                f"gs://{bucket}", "--project", project_id],
               check=False, quiet=True)
    if desc.returncode != 0:
        run(["gcloud", "storage", "buckets", "create", f"gs://{bucket}",
             "--project", project_id, "--location", region,
             "--uniform-bucket-level-access"], quiet=True)
    run(["gcloud", "storage", "buckets", "update", f"gs://{bucket}",
         "--versioning"], quiet=True)
    prefix = f"gcp/{cluster_name}/{env_name}/{region}"
    Path(backend_file).write_text(
        f'bucket = "{bucket}"\nprefix = "{prefix}"\n')


def prepare_azure_backend(cluster_name: str, env_name: str, region: str,
                          subscription_id: str, backend_file: str) -> None:
    rg = sanitize_name(f"rc-tfstate-rg-{region}")
    sa = f"rctf{hash8(f'{subscription_id}-{region}')}"
    container = "tfstate"
    key = f"azure/{cluster_name}/{env_name}/{region}/terraform.tfstate"

    run(["az", "group", "create", "--name", rg, "--location", region],
        quiet=True)
    show = run(["az", "storage", "account", "show", "--name", sa,
                "--resource-group", rg], check=False, quiet=True)
    if show.returncode != 0:
        run(["az", "storage", "account", "create", "--name", sa,
             "--resource-group", rg, "--location", region, "--sku",
             "Standard_LRS", "--kind", "StorageV2",
             "--allow-blob-public-access", "false",
             "--min-tls-version", "TLS1_2"], quiet=True)
    run(["az", "storage", "container", "create", "--name", container,
         "--account-name", sa, "--auth-mode", "login"], quiet=True)

    Path(backend_file).write_text(
        f'resource_group_name  = "{rg}"\n'
        f'storage_account_name = "{sa}"\n'
        f'container_name       = "{container}"\n'
        f'key                  = "{key}"\n')


def prepare_backend(cloud: str, cluster_name: str, env_name: str,
                    region: str, info: dict, backend_file: str) -> None:
    if cloud == "aws":
        prepare_aws_backend(cluster_name, env_name, region, backend_file)
    elif cloud == "gcp":
        prepare_gcp_backend(cluster_name, env_name, region,
                            info["project_id"], backend_file)
    elif cloud == "azure":
        prepare_azure_backend(cluster_name, env_name, region,
                              info["subscription_id"], backend_file)


# ---------------------------------------------------------------------------
# Terraform helpers
# ---------------------------------------------------------------------------

TF_STACK = {"aws": "eks", "gcp": "gke", "azure": "aks"}


def terraform_init(cloud: str, backend_file: str) -> None:
    tf_dir = ROOT_DIR / "terraform" / TF_STACK[cloud]
    run(["terraform", "init", "-reconfigure",
         f"-backend-config={backend_file}"], timeout=600)


def terraform_apply(vars_file: str) -> None:
    run(["terraform", "apply", "-auto-approve", "-input=false",
         f"-var-file={vars_file}"], timeout=1800)


def terraform_destroy(vars_file: str) -> bool:
    result = run(["terraform", "destroy", "-auto-approve", "-input=false",
                  f"-var-file={vars_file}"], check=False, timeout=1800)
    return result.returncode == 0


def terraform_output(name: str) -> str:
    return run_output(["terraform", "output", "-raw", name])


# ---------------------------------------------------------------------------
# Kubeconfig helpers
# ---------------------------------------------------------------------------

def update_kubeconfig(cloud: str, cluster_name: str, region: str,
                      info: dict, *, public_api: bool = False) -> None:
    if cloud == "aws":
        run(["aws", "eks", "update-kubeconfig", "--name", cluster_name,
             "--region", region, "--alias", cluster_name])
    elif cloud == "gcp":
        cmd = ["gcloud", "container", "clusters", "get-credentials",
               cluster_name, "--region", region]
        if not public_api:
            cmd.append("--internal-ip")
        run(cmd)
    elif cloud == "azure":
        rg = f"rg-{info['base_name']}-{cluster_name.split('-')[-2]}-aks"
        rg = f"rg-{cluster_name}"
        run(["az", "aks", "get-credentials", "--name", cluster_name,
             "--resource-group", rg, "--overwrite-existing"])


def resolve_kube_context(cluster_name: str) -> Optional[str]:
    contexts = run_output(
        ["kubectl", "config", "get-contexts", "-o", "name"],
        check=False, quiet=True)
    for ctx in contexts.splitlines():
        if ctx == cluster_name:
            return ctx
    for ctx in contexts.splitlines():
        if cluster_name in ctx:
            return ctx
    return None


def kube_api_reachable() -> bool:
    r = run(["kubectl", "--request-timeout=10s", "get", "--raw=/readyz"],
            check=False, quiet=True)
    return r.returncode == 0


# ---------------------------------------------------------------------------
# AWS cleanup functions
# ---------------------------------------------------------------------------

def delete_kubernetes_lb_resources(cluster_name: str, region: str) -> None:
    """Delete K8s LoadBalancer services and Ingresses (EKS)."""
    print(f"Deleting Kubernetes LB resources for EKS cluster: {cluster_name}")
    status = run_output(
        ["aws", "eks", "describe-cluster", "--name", cluster_name,
         "--region", region, "--query", "cluster.status", "--output", "text"],
        check=False, quiet=True) or "UNKNOWN"

    if status not in ("ACTIVE", "DELETING"):
        print(f"  Cluster status {status}, skipping K8s cleanup.")
        return

    run(["aws", "eks", "update-kubeconfig", "--name", cluster_name,
         "--region", region], check=False, quiet=True)
    ctx = resolve_kube_context(cluster_name)
    if not ctx:
        return

    try:
        svc_json = run_output(
            ["kubectl", "--context", ctx, "get", "svc", "-A", "-o", "json"],
            check=False, quiet=True)
        for item in json.loads(svc_json).get("items", []):
            if item.get("spec", {}).get("type") == "LoadBalancer":
                ns = item["metadata"]["namespace"]
                nm = item["metadata"]["name"]
                run(["kubectl", "--context", ctx, "delete", "svc", nm,
                     "-n", ns, "--timeout=30s", "--wait=false"],
                    check=False, quiet=True)
    except (json.JSONDecodeError, subprocess.TimeoutExpired):
        pass

    run(["kubectl", "--context", ctx, "delete", "ingress", "-A", "--all",
         "--timeout=30s", "--wait=false"], check=False, quiet=True)
    time.sleep(10)


def cleanup_eks_addons_cli(cluster_name: str, region: str) -> None:
    print(f"Deleting EKS addons for cluster: {cluster_name}")
    addons_str = run_output(
        ["aws", "eks", "list-addons", "--cluster-name", cluster_name,
         "--region", region, "--query", "addons", "--output", "text"],
        check=False, quiet=True)
    if not addons_str:
        return
    for addon in addons_str.split():
        print(f"  Deleting addon: {addon}")
        run(["aws", "eks", "delete-addon", "--cluster-name", cluster_name,
             "--addon-name", addon, "--region", region, "--preserve=false"],
            check=False, quiet=True)
    time.sleep(10)


def cleanup_eks_nodegroups_cli(cluster_name: str, region: str) -> None:
    print(f"Deleting EKS node groups for cluster: {cluster_name}")
    ngs_str = run_output(
        ["aws", "eks", "list-nodegroups", "--cluster-name", cluster_name,
         "--region", region, "--query", "nodegroups", "--output", "text"],
        check=False, quiet=True)
    if not ngs_str:
        return
    for ng in ngs_str.split():
        print(f"  Deleting node group: {ng}")
        run(["aws", "eks", "delete-nodegroup", "--cluster-name", cluster_name,
             "--nodegroup-name", ng, "--region", region],
            check=False, quiet=True)

    # Wait for deletion
    for ng in ngs_str.split():
        for i in range(40):
            status = run_output(
                ["aws", "eks", "describe-nodegroup", "--cluster-name",
                 cluster_name, "--nodegroup-name", ng, "--region", region,
                 "--query", "nodegroup.status", "--output", "text"],
                check=False, quiet=True)
            if not status or "error" in status.lower():
                print(f"  Node group {ng} deleted.")
                break
            print(f"  Node group {ng} status: {status} ({i+1}/40)")
            time.sleep(15)


def _find_vpc_id(cluster_name: str, region: str) -> Optional[str]:
    """Find VPC ID by tag patterns matching the cluster."""
    base_pattern = re.sub(r"-[a-z]+-eks$", "", cluster_name)
    vpc_id = run_output(
        ["aws", "ec2", "describe-vpcs", "--region", region,
         "--filters", f"Name=tag:Name,Values=*{base_pattern}*",
         "--query", "Vpcs[0].VpcId", "--output", "text"],
        check=False, quiet=True)
    if vpc_id and vpc_id != "None":
        return vpc_id

    vpc_id = run_output(
        ["aws", "ec2", "describe-vpcs", "--region", region,
         "--filters",
         f"Name=tag:kubernetes.io/cluster/{cluster_name},Values=shared,owned",
         "--query", "Vpcs[0].VpcId", "--output", "text"],
        check=False, quiet=True)
    if vpc_id and vpc_id != "None":
        return vpc_id
    return None


def cleanup_eks_aws_resources(cluster_name: str, region: str) -> None:
    """Nuclear cleanup of AWS resources blocking VPC deletion."""
    print(f"Starting AWS resource cleanup for cluster: {cluster_name}")

    vpc_id = _find_vpc_id(cluster_name, region)
    if not vpc_id:
        print("  Could not resolve VPC ID, skipping.")
        return
    print(f"  Target VPC: {vpc_id}")

    # Node groups
    cleanup_eks_nodegroups_cli(cluster_name, region)

    # NAT Gateways
    print("  Cleaning up NAT Gateways...")
    nat_eip_allocs: list[str] = []
    nat_gw_ids = run_output(
        ["aws", "ec2", "describe-nat-gateways", "--region", region,
         "--filter", f"Name=vpc-id,Values={vpc_id}",
         "--query", "NatGateways[?State!=`deleted`].NatGatewayId",
         "--output", "text"],
        check=False, quiet=True).split()

    for ngw in nat_gw_ids:
        if not ngw:
            continue
        eips = run_output(
            ["aws", "ec2", "describe-nat-gateways", "--region", region,
             "--nat-gateway-ids", ngw,
             "--query", "NatGateways[0].NatGatewayAddresses[*].AllocationId",
             "--output", "text"],
            check=False, quiet=True).split()
        nat_eip_allocs.extend(a for a in eips if a and a != "None")
        print(f"    Deleting NAT Gateway: {ngw}")
        run(["aws", "ec2", "delete-nat-gateway", "--region", region,
             "--nat-gateway-id", ngw], check=False, quiet=True)

    if nat_gw_ids:
        for i in range(30):
            remaining = run_output(
                ["aws", "ec2", "describe-nat-gateways", "--region", region,
                 "--filter", f"Name=vpc-id,Values={vpc_id}",
                 "--query", "NatGateways[?State!=`deleted`].NatGatewayId",
                 "--output", "text"],
                check=False, quiet=True).strip()
            if not remaining:
                print("    All NAT Gateways deleted.")
                break
            print(f"    Waiting for NAT GW deletion ({i+1}/30)...")
            time.sleep(20)

    for alloc in nat_eip_allocs:
        print(f"    Releasing NAT GW EIP: {alloc}")
        run(["aws", "ec2", "release-address", "--region", region,
             "--allocation-id", alloc], check=False, quiet=True)

    # Load balancers
    print("  Cleaning up load balancers...")
    elbv2_arns = run_output(
        ["aws", "elbv2", "describe-load-balancers", "--region", region,
         "--query", f"LoadBalancers[?VpcId=='{vpc_id}'].LoadBalancerArn",
         "--output", "text"],
        check=False, quiet=True).split()
    for arn in elbv2_arns:
        if not arn:
            continue
        run(["aws", "elbv2", "delete-load-balancer", "--region", region,
             "--load-balancer-arn", arn], check=False, quiet=True)

    elb_names = run_output(
        ["aws", "elb", "describe-load-balancers", "--region", region,
         "--query", f"LoadBalancerDescriptions[?VpcId=='{vpc_id}'].LoadBalancerName",
         "--output", "text"],
        check=False, quiet=True).split()
    for name in elb_names:
        if not name:
            continue
        run(["aws", "elb", "delete-load-balancer", "--region", region,
             "--load-balancer-name", name], check=False, quiet=True)

    if elbv2_arns or elb_names:
        time.sleep(30)

    # Target groups
    tg_arns = run_output(
        ["aws", "elbv2", "describe-target-groups", "--region", region,
         "--query", f"TargetGroups[?VpcId=='{vpc_id}'].TargetGroupArn",
         "--output", "text"],
        check=False, quiet=True).split()
    for arn in tg_arns:
        if arn:
            run(["aws", "elbv2", "delete-target-group", "--region", region,
                 "--target-group-arn", arn], check=False, quiet=True)

    # VPC Endpoints
    vpce_ids = run_output(
        ["aws", "ec2", "describe-vpc-endpoints", "--region", region,
         "--filters", f"Name=vpc-id,Values={vpc_id}",
         "--query", "VpcEndpoints[*].VpcEndpointId", "--output", "text"],
        check=False, quiet=True).split()
    for vpce in vpce_ids:
        if vpce:
            run(["aws", "ec2", "delete-vpc-endpoints", "--region", region,
                 "--vpc-endpoint-ids", vpce], check=False, quiet=True)

    # Security groups — strip rules then delete
    print("  Cleaning up security groups...")
    sg_ids = run_output(
        ["aws", "ec2", "describe-security-groups", "--region", region,
         "--filters", f"Name=vpc-id,Values={vpc_id}",
         "--query", "SecurityGroups[?GroupName!=`default`].GroupId",
         "--output", "text"],
        check=False, quiet=True).split()
    for sg in sg_ids:
        if not sg:
            continue
        ingress = run_output(
            ["aws", "ec2", "describe-security-groups", "--region", region,
             "--group-ids", sg,
             "--query", "SecurityGroups[0].IpPermissions", "--output", "json"],
            check=False, quiet=True)
        if ingress and ingress != "[]":
            run(["aws", "ec2", "revoke-security-group-ingress",
                 "--region", region, "--group-id", sg,
                 "--ip-permissions", ingress], check=False, quiet=True)
        egress = run_output(
            ["aws", "ec2", "describe-security-groups", "--region", region,
             "--group-ids", sg,
             "--query", "SecurityGroups[0].IpPermissionsEgress",
             "--output", "json"],
            check=False, quiet=True)
        if egress and egress != "[]":
            run(["aws", "ec2", "revoke-security-group-egress",
                 "--region", region, "--group-id", sg,
                 "--ip-permissions", egress], check=False, quiet=True)

    for sg in sg_ids:
        if sg:
            run(["aws", "ec2", "delete-security-group", "--region", region,
                 "--group-id", sg], check=False, quiet=True)

    # ENIs with retry
    print("  Cleaning up ENIs (with retries)...")
    for attempt in range(6):
        eni_ids = run_output(
            ["aws", "ec2", "describe-network-interfaces", "--region", region,
             "--filters", f"Name=vpc-id,Values={vpc_id}",
             "--query", "NetworkInterfaces[*].NetworkInterfaceId",
             "--output", "text"],
            check=False, quiet=True).split()
        eni_ids = [e for e in eni_ids if e]
        if not eni_ids:
            print("    All ENIs cleaned up.")
            break

        print(f"    ENI sweep {attempt+1}/6: {len(eni_ids)} ENIs remaining")
        for eni in eni_ids:
            status = run_output(
                ["aws", "ec2", "describe-network-interfaces", "--region",
                 region, "--network-interface-ids", eni,
                 "--query", "NetworkInterfaces[0].Status", "--output", "text"],
                check=False, quiet=True)
            if not status:
                continue
            if status == "in-use":
                att_id = run_output(
                    ["aws", "ec2", "describe-network-interfaces", "--region",
                     region, "--network-interface-ids", eni,
                     "--query", "NetworkInterfaces[0].Attachment.AttachmentId",
                     "--output", "text"],
                    check=False, quiet=True)
                if att_id and att_id != "None":
                    run(["aws", "ec2", "detach-network-interface", "--region",
                         region, "--attachment-id", att_id, "--force"],
                        check=False, quiet=True)
            else:
                run(["aws", "ec2", "delete-network-interface", "--region",
                     region, "--network-interface-id", eni],
                    check=False, quiet=True)
        if attempt < 5:
            time.sleep(15)

    # Final ENI pass
    leftover = run_output(
        ["aws", "ec2", "describe-network-interfaces", "--region", region,
         "--filters", f"Name=vpc-id,Values={vpc_id}",
         "Name=status,Values=available",
         "--query", "NetworkInterfaces[*].NetworkInterfaceId",
         "--output", "text"],
        check=False, quiet=True).split()
    for eni in leftover:
        if eni:
            run(["aws", "ec2", "delete-network-interface", "--region", region,
                 "--network-interface-id", eni], check=False, quiet=True)

    # EIP sweep
    print("  Final EIP sweep...")
    base_pattern = re.sub(r"-[a-z]+-eks$", "", cluster_name)
    eips_json = run_output(
        ["aws", "ec2", "describe-addresses", "--region", region,
         "--query", "Addresses[*]", "--output", "json"],
        check=False, quiet=True)
    try:
        eips = json.loads(eips_json) if eips_json else []
    except json.JSONDecodeError:
        eips = []

    for eip in eips:
        alloc = eip.get("AllocationId", "")
        if not alloc:
            continue
        eni_id = eip.get("NetworkInterfaceId")
        should_release = False

        if eni_id:
            eni_vpc = run_output(
                ["aws", "ec2", "describe-network-interfaces", "--region",
                 region, "--network-interface-ids", eni_id,
                 "--query", "NetworkInterfaces[0].VpcId", "--output", "text"],
                check=False, quiet=True)
            if eni_vpc == vpc_id:
                should_release = True
                assoc = eip.get("AssociationId")
                if assoc:
                    run(["aws", "ec2", "disassociate-address", "--region",
                         region, "--association-id", assoc],
                        check=False, quiet=True)
                    time.sleep(2)
        else:
            tags_str = " ".join(
                t.get("Value", "") for t in (eip.get("Tags") or []))
            if any(p in tags_str for p in (vpc_id, cluster_name, base_pattern)):
                should_release = True

        if should_release:
            print(f"    Releasing EIP: {alloc}")
            run(["aws", "ec2", "release-address", "--region", region,
                 "--allocation-id", alloc], check=False, quiet=True)

    # Route tables
    print("  Cleaning up route tables...")
    rt_ids = run_output(
        ["aws", "ec2", "describe-route-tables", "--region", region,
         "--filters", f"Name=vpc-id,Values={vpc_id}",
         "--query", "RouteTables[*].RouteTableId", "--output", "text"],
        check=False, quiet=True).split()
    for rt in rt_ids:
        if not rt:
            continue
        assocs = run_output(
            ["aws", "ec2", "describe-route-tables", "--region", region,
             "--route-table-ids", rt,
             "--query", "RouteTables[0].Associations[?!Main].RouteTableAssociationId",
             "--output", "text"],
            check=False, quiet=True).split()
        for assoc in assocs:
            if assoc and assoc != "None":
                run(["aws", "ec2", "disassociate-route-table", "--region",
                     region, "--association-id", assoc],
                    check=False, quiet=True)

    for rt in rt_ids:
        if not rt:
            continue
        is_main = run_output(
            ["aws", "ec2", "describe-route-tables", "--region", region,
             "--route-table-ids", rt,
             "--query", "RouteTables[0].Associations[?Main==`true`] | length(@)",
             "--output", "text"],
            check=False, quiet=True)
        if is_main == "0":
            run(["aws", "ec2", "delete-route-table", "--region", region,
                 "--route-table-id", rt], check=False, quiet=True)

    # Retry SG deletion
    sg_ids = run_output(
        ["aws", "ec2", "describe-security-groups", "--region", region,
         "--filters", f"Name=vpc-id,Values={vpc_id}",
         "--query", "SecurityGroups[?GroupName!=`default`].GroupId",
         "--output", "text"],
        check=False, quiet=True).split()
    for sg in sg_ids:
        if sg:
            run(["aws", "ec2", "delete-security-group", "--region", region,
                 "--group-id", sg], check=False, quiet=True)

    print(f"  AWS cleanup complete for VPC: {vpc_id}")


# ---------------------------------------------------------------------------
# Azure cleanup functions
# ---------------------------------------------------------------------------

def delete_kubernetes_lb_resources_aks(cluster_name: str,
                                       region: str) -> None:
    rg = f"rg-{cluster_name}"
    print(f"Deleting Kubernetes LB resources for AKS cluster: {cluster_name}")

    status = run_output(
        ["az", "aks", "show", "--name", cluster_name, "--resource-group", rg,
         "--query", "provisioningState", "-o", "tsv"],
        check=False, quiet=True) or "UNKNOWN"

    if status not in ("Succeeded", "Deleting"):
        print(f"  Cluster status {status}, skipping K8s cleanup.")
        return

    run(["az", "aks", "get-credentials", "--name", cluster_name,
         "--resource-group", rg, "--overwrite-existing"],
        check=False, quiet=True)
    ctx = resolve_kube_context(cluster_name)
    if not ctx:
        return

    try:
        svc_json = run_output(
            ["kubectl", "--context", ctx, "get", "svc", "-A", "-o", "json"],
            check=False, quiet=True)
        for item in json.loads(svc_json).get("items", []):
            if item.get("spec", {}).get("type") == "LoadBalancer":
                ns = item["metadata"]["namespace"]
                nm = item["metadata"]["name"]
                run(["kubectl", "--context", ctx, "delete", "svc", nm,
                     "-n", ns, "--timeout=30s", "--wait=false"],
                    check=False, quiet=True)
    except (json.JSONDecodeError, subprocess.TimeoutExpired):
        pass

    run(["kubectl", "--context", ctx, "delete", "ingress", "-A", "--all",
         "--timeout=30s", "--wait=false"], check=False, quiet=True)
    time.sleep(15)


def cleanup_aks_azure_resources(cluster_name: str, region: str) -> None:
    rg = f"rg-{cluster_name}"
    print(f"Starting Azure resource cleanup for AKS cluster: {cluster_name}")

    mc_rg = run_output(
        ["az", "aks", "show", "--name", cluster_name, "--resource-group", rg,
         "--query", "nodeResourceGroup", "-o", "tsv"],
        check=False, quiet=True)

    for target_rg in (mc_rg, rg):
        if not target_rg:
            continue
        print(f"  Cleaning resource group: {target_rg}")

        # Load balancers
        lb_ids = run_output(
            ["az", "network", "lb", "list", "-g", target_rg,
             "--query", "[].id", "-o", "tsv"],
            check=False, quiet=True).splitlines()
        for lb_id in lb_ids:
            if lb_id:
                run(["az", "network", "lb", "delete", "--ids", lb_id],
                    check=False, quiet=True)

        # Public IPs
        pip_ids = run_output(
            ["az", "network", "public-ip", "list", "-g", target_rg,
             "--query", "[].id", "-o", "tsv"],
            check=False, quiet=True).splitlines()
        for pip_id in pip_ids:
            if pip_id:
                run(["az", "network", "public-ip", "delete", "--ids", pip_id],
                    check=False, quiet=True)

    # NSGs and NICs in main RG
    nsg_ids = run_output(
        ["az", "network", "nsg", "list", "-g", rg,
         "--query", "[].id", "-o", "tsv"],
        check=False, quiet=True).splitlines()
    for nsg_id in nsg_ids:
        if nsg_id:
            run(["az", "network", "nsg", "delete", "--ids", nsg_id],
                check=False, quiet=True)

    nic_ids = run_output(
        ["az", "network", "nic", "list", "-g", rg,
         "--query", "[].id", "-o", "tsv"],
        check=False, quiet=True).splitlines()
    for nic_id in nic_ids:
        if nic_id:
            run(["az", "network", "nic", "delete", "--ids", nic_id],
                check=False, quiet=True)

    print(f"  Azure cleanup complete for cluster: {cluster_name}")


# ---------------------------------------------------------------------------
# GCP cleanup functions
# ---------------------------------------------------------------------------

def delete_kubernetes_lb_resources_gke(cluster_name: str,
                                       region: str) -> None:
    print(f"Deleting Kubernetes LB resources for GKE cluster: {cluster_name}")
    status = run_output(
        ["gcloud", "container", "clusters", "describe", cluster_name,
         "--region", region, "--format=value(status)"],
        check=False, quiet=True) or "UNKNOWN"

    if status not in ("RUNNING", "RECONCILING"):
        print(f"  Cluster status {status}, skipping K8s cleanup.")
        return

    run(["gcloud", "container", "clusters", "get-credentials", cluster_name,
         "--region", region], check=False, quiet=True)
    ctx = resolve_kube_context(cluster_name)
    if not ctx:
        return

    try:
        svc_json = run_output(
            ["kubectl", "--context", ctx, "get", "svc", "-A", "-o", "json"],
            check=False, quiet=True)
        for item in json.loads(svc_json).get("items", []):
            if item.get("spec", {}).get("type") == "LoadBalancer":
                ns = item["metadata"]["namespace"]
                nm = item["metadata"]["name"]
                run(["kubectl", "--context", ctx, "delete", "svc", nm,
                     "-n", ns, "--timeout=30s", "--wait=false"],
                    check=False, quiet=True)
    except (json.JSONDecodeError, subprocess.TimeoutExpired):
        pass

    run(["kubectl", "--context", ctx, "delete", "ingress", "-A", "--all",
         "--timeout=30s", "--wait=false"], check=False, quiet=True)
    time.sleep(15)


def cleanup_gke_gcp_resources(cluster_name: str, region: str) -> None:
    print(f"Starting GCP resource cleanup for cluster: {cluster_name}")

    project_id = run_output(
        ["gcloud", "config", "get-value", "project"],
        quiet=True).strip()
    if not project_id or project_id == "(unset)":
        print("  gcloud project not set, skipping.")
        return

    vpc_name = f"{cluster_name}-vpc"
    vpc_link = run_output(
        ["gcloud", "compute", "networks", "describe", vpc_name,
         "--project", project_id, "--format=value(selfLink)"],
        check=False, quiet=True)
    if not vpc_link:
        print(f"  VPC {vpc_name} not found, skipping.")
        return
    print(f"  Target VPC: {vpc_name}")

    base_env = cluster_name.removesuffix("-gke")

    # Disable deletion protection
    print("  Disabling deletion protection...")
    run(["gcloud", "container", "clusters", "update", cluster_name,
         "--region", region, "--project", project_id,
         "--no-deletion-protection", "--quiet"], check=False, quiet=True)

    # Forwarding rules
    print("  Cleaning up forwarding rules...")
    fwd_csv = run_output(
        ["gcloud", "compute", "forwarding-rules", "list", "--project",
         project_id,
         f"--filter=network:{vpc_name} OR network:{vpc_link}",
         "--format=csv[no-heading](name,region.basename())"],
        check=False, quiet=True)
    for line in fwd_csv.splitlines():
        if not line:
            continue
        parts = line.split(",", 1)
        fr_name = parts[0]
        fr_region = parts[1] if len(parts) > 1 and parts[1] else None
        if fr_region:
            run(["gcloud", "compute", "forwarding-rules", "delete", fr_name,
                 "--region", fr_region, "--project", project_id, "--quiet"],
                check=False, quiet=True)
        else:
            run(["gcloud", "compute", "forwarding-rules", "delete", fr_name,
                 "--global", "--project", project_id, "--quiet"],
                check=False, quiet=True)

    # Target pools
    print("  Cleaning up target pools...")
    tps = run_output(
        ["gcloud", "compute", "target-pools", "list", "--project", project_id,
         f"--filter=region:{region}",
         "--format=value(name)"],
        check=False, quiet=True).split()
    for tp in tps:
        if tp:
            run(["gcloud", "compute", "target-pools", "delete", tp,
                 "--region", region, "--project", project_id, "--quiet"],
                check=False, quiet=True)

    # Backend services
    print("  Cleaning up backend services...")
    bs_csv = run_output(
        ["gcloud", "compute", "backend-services", "list", "--project",
         project_id,
         f"--filter=network:{vpc_name} OR network:{vpc_link}",
         "--format=csv[no-heading](name,region.basename())"],
        check=False, quiet=True)
    for line in bs_csv.splitlines():
        if not line:
            continue
        parts = line.split(",", 1)
        bs_name = parts[0]
        bs_region = parts[1] if len(parts) > 1 and parts[1] else None
        if bs_region:
            run(["gcloud", "compute", "backend-services", "delete", bs_name,
                 "--region", bs_region, "--project", project_id, "--quiet"],
                check=False, quiet=True)
        else:
            run(["gcloud", "compute", "backend-services", "delete", bs_name,
                 "--global", "--project", project_id, "--quiet"],
                check=False, quiet=True)

    # Firewall rules
    print("  Cleaning up firewall rules...")
    fw_rules = run_output(
        ["gcloud", "compute", "firewall-rules", "list", "--project",
         project_id,
         f"--filter=network:{vpc_name} OR network:{vpc_link}",
         "--format=value(name)"],
        check=False, quiet=True).split()
    for fw in fw_rules:
        if fw:
            run(["gcloud", "compute", "firewall-rules", "delete", fw,
                 "--project", project_id, "--quiet"],
                check=False, quiet=True)

    # Cloud NAT / Router
    router_name = f"{base_env}-router"
    print(f"  Cleaning up Cloud NAT/Router: {router_name}")
    nats = run_output(
        ["gcloud", "compute", "routers", "nats", "list",
         "--router", router_name, "--region", region, "--project", project_id,
         "--format=value(name)"],
        check=False, quiet=True).split()
    for nat_name in nats:
        if nat_name:
            run(["gcloud", "compute", "routers", "nats", "delete", nat_name,
                 "--router", router_name, "--region", region,
                 "--project", project_id, "--quiet"],
                check=False, quiet=True)
    run(["gcloud", "compute", "routers", "delete", router_name,
         "--region", region, "--project", project_id, "--quiet"],
        check=False, quiet=True)

    # External addresses
    print("  Cleaning up external addresses...")
    addrs = run_output(
        ["gcloud", "compute", "addresses", "list", "--project", project_id,
         f"--filter=region:{region} AND name~{base_env}",
         "--format=value(name)"],
        check=False, quiet=True).split()
    for addr in addrs:
        if addr:
            run(["gcloud", "compute", "addresses", "delete", addr,
                 "--region", region, "--project", project_id, "--quiet"],
                check=False, quiet=True)

    print(f"  GCP cleanup complete for cluster: {cluster_name}")


# ---------------------------------------------------------------------------
# Dispatch cleanup by cloud
# ---------------------------------------------------------------------------

def pre_destroy_cleanup(cloud: str, cluster_name: str, region: str) -> None:
    if cloud == "aws":
        delete_kubernetes_lb_resources(cluster_name, region)
        cleanup_eks_addons_cli(cluster_name, region)
        cleanup_eks_aws_resources(cluster_name, region)
    elif cloud == "azure":
        delete_kubernetes_lb_resources_aks(cluster_name, region)
        cleanup_aks_azure_resources(cluster_name, region)
    elif cloud == "gcp":
        delete_kubernetes_lb_resources_gke(cluster_name, region)
        cleanup_gke_gcp_resources(cluster_name, region)


def retry_cleanup(cloud: str, cluster_name: str, region: str) -> None:
    if cloud == "aws":
        cleanup_eks_aws_resources(cluster_name, region)
    elif cloud == "azure":
        cleanup_aks_azure_resources(cluster_name, region)
    elif cloud == "gcp":
        cleanup_gke_gcp_resources(cluster_name, region)
