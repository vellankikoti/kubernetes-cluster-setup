#!/usr/bin/env python3
"""Create a Kubernetes cluster — equivalent to scripts/create-cluster.sh,
scripts/bootstrap.sh, and scripts/validation.sh combined.

Usage:
    python create_cluster.py --cloud aws|gcp|azure --name <name> \
        --env dev|qa|staging|prod --region <region> \
        [--public-api] [--full-validation]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

from cluster_lib import (
    ROOT_DIR,
    TF_STACK,
    derive_cluster_info,
    get_public_ip,
    kube_api_reachable,
    prepare_backend,
    require_cmd,
    resolve_kube_context,
    run,
    run_output,
    terraform_init,
    terraform_output,
    update_kubeconfig,
    write_tfvars,
)

VALID_ENVS = ("dev", "qa", "staging", "prod")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Create a Kubernetes cluster")
    p.add_argument("--cloud", required=True, choices=["aws", "gcp", "azure"])
    p.add_argument("--name", required=True, help="Cluster base name")
    p.add_argument("--env", required=True, choices=VALID_ENVS,
                   dest="env_name")
    p.add_argument("--region", required=True)
    p.add_argument("--public-api", action="store_true", default=False)
    p.add_argument("--full-validation", action="store_true", default=False)
    return p.parse_args()


# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

def kctl(ctx: str, *args: str, **kwargs) -> subprocess.CompletedProcess:
    return run(["kubectl", "--context", ctx, *args], **kwargs)


def kctl_output(ctx: str, *args: str, **kwargs) -> str:
    return run_output(["kubectl", "--context", ctx, *args], **kwargs)


def bootstrap(cloud: str, cluster_name: str, region: str, env_name: str,
              ctx: str, *, autoscaler_role_arn: str = "",
              public_api: bool = False) -> None:
    """Install common resources, ingress, metrics-server, autoscaler."""
    print(f"\n--- Bootstrap: {cluster_name} ({cloud}) ---")

    # Add helm repos
    for repo, url in [
        ("ingress-nginx", "https://kubernetes.github.io/ingress-nginx"),
        ("metrics-server", "https://kubernetes-sigs.github.io/metrics-server/"),
        ("autoscaler", "https://kubernetes.github.io/autoscaler"),
    ]:
        run(["helm", "repo", "add", repo, url], check=False, quiet=True)
    run(["helm", "repo", "update"], quiet=True)

    # Apply common resources
    common_dir = ROOT_DIR / "common-resources"
    for manifest in ("namespaces.yaml", "priority-classes.yaml",
                     "network-policies.yaml", "resource-quotas.yaml",
                     "limit-ranges.yaml", "pod-disruption-budgets.yaml"):
        path = common_dir / manifest
        if path.exists():
            kctl(ctx, "apply", "-f", str(path), quiet=True)

    # Check if Prometheus CRDs exist
    has_servicemonitor = kctl(
        ctx, "get", "crd", "servicemonitors.monitoring.coreos.com",
        check=False, quiet=True).returncode == 0

    nginx_replicas = "3" if env_name == "prod" else "1"
    nginx_values = str(ROOT_DIR / "addons" / "ingress" / "nginx-values.yaml")

    helm_cmd = [
        "helm", "upgrade", "--install", "ingress-nginx",
        "ingress-nginx/ingress-nginx",
        "-n", "ingress-nginx", "--create-namespace",
        "--kube-context", ctx,
        "-f", nginx_values,
        "--set", f"controller.replicaCount={nginx_replicas}",
        "--wait", "--timeout", "15m",
    ]
    if not has_servicemonitor:
        helm_cmd += ["--set", "controller.metrics.serviceMonitor.enabled=false"]
    run(helm_cmd, timeout=900)

    # Metrics server (not needed on AKS)
    if cloud != "azure":
        ms_values = str(ROOT_DIR / "addons" / "observability" /
                        "metrics-server-values.yaml")
        run(["helm", "upgrade", "--install", "metrics-server",
             "metrics-server/metrics-server", "-n", "kube-system",
             "--kube-context", ctx, "-f", ms_values,
             "--wait", "--timeout", "10m"], timeout=600)

    # Cloud-specific
    if cloud == "aws":
        if not autoscaler_role_arn:
            raise RuntimeError("--autoscaler-role-arn required for AWS")

        sc_file = ROOT_DIR / "addons" / "storage" / "eks-gp3-storageclass.yaml"
        kctl(ctx, "apply", "-f", str(sc_file), quiet=True)

        # Generate cluster-autoscaler values
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml",
                                          delete=False) as f:
            f.write(f"""\
cloudProvider: aws
fullnameOverride: cluster-autoscaler
autoDiscovery:
  clusterName: {cluster_name}
awsRegion: {region}
rbac:
  create: true
  serviceAccount:
    create: true
    name: cluster-autoscaler
    annotations:
      eks.amazonaws.com/role-arn: {autoscaler_role_arn}
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
""")
            ca_values = f.name

        run(["helm", "upgrade", "--install", "cluster-autoscaler",
             "autoscaler/cluster-autoscaler", "-n", "kube-system",
             "--kube-context", ctx, "-f", ca_values,
             "--wait", "--timeout", "10m"], timeout=600)
        os.unlink(ca_values)

        kctl(ctx, "-n", "kube-system", "rollout", "restart",
             "deployment/cluster-autoscaler", quiet=True)
        kctl(ctx, "-n", "kube-system", "rollout", "status",
             "deployment/cluster-autoscaler", "--timeout=600s", quiet=True)

    elif cloud == "gcp":
        sc_file = ROOT_DIR / "addons" / "storage" / "gke-pd-storageclass.yaml"
        kctl(ctx, "apply", "-f", str(sc_file), quiet=True)

    elif cloud == "azure":
        print("  Using managed Azure storage classes.")

    # Wait for deployments
    kctl(ctx, "wait", "--for=condition=Available",
         "deployment/ingress-nginx-controller", "-n", "ingress-nginx",
         "--timeout=600s", quiet=True)
    if cloud != "azure":
        kctl(ctx, "wait", "--for=condition=Available",
             "deployment/metrics-server", "-n", "kube-system",
             "--timeout=600s", quiet=True)
    if cloud == "aws":
        kctl(ctx, "wait", "--for=condition=Available",
             "deployment/cluster-autoscaler", "-n", "kube-system",
             "--timeout=600s", quiet=True)

    print(f"Bootstrap completed for {cluster_name} ({cloud})")


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def validate(cloud: str, cluster_name: str, region: str, ctx: str,
             *, full_validation: bool = False) -> dict:
    """Run smoke / full validation — returns ingress_endpoint, storage_class."""
    print(f"\n--- Validation: {cluster_name} ({cloud}) ---")

    # Check nodes
    kctl(ctx, "--request-timeout=20s", "get", "nodes", quiet=True)

    # Check for non-running pods
    non_running = kctl_output(
        ctx, "--request-timeout=20s", "get", "pods", "-A",
        "--field-selector=status.phase!=Running,status.phase!=Succeeded",
        "--no-headers", check=False, quiet=True)
    if non_running and "No resources found" not in non_running:
        print(f"WARNING: Non-running pods detected:\n{non_running}")

    # Create test namespace
    test_ns = "validation"
    kctl(ctx, "create", "ns", test_ns, "--dry-run=client", "-o", "yaml",
         quiet=True)
    run(["kubectl", "--context", ctx, "create", "ns", test_ns,
         "--dry-run=client", "-o", "yaml"], quiet=True)
    pipe = subprocess.run(
        f"kubectl --context {ctx} create ns {test_ns} --dry-run=client -o yaml | kubectl --context {ctx} apply -f -",
        shell=True, capture_output=True, text=True)

    # PVC test
    pvc_yaml = """\
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-test
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi"""
    subprocess.run(
        f"echo '{pvc_yaml}' | kubectl --context {ctx} apply -n {test_ns} -f -",
        shell=True, capture_output=True, text=True)

    pod_yaml = """\
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
        claimName: pvc-test"""
    subprocess.run(
        f"echo '{pod_yaml}' | kubectl --context {ctx} apply -n {test_ns} -f -",
        shell=True, capture_output=True, text=True)

    kctl(ctx, "wait", "-n", test_ns,
         "--for=jsonpath={.status.phase}=Bound", "pvc/pvc-test",
         "--timeout=300s", quiet=True, check=False)
    kctl(ctx, "wait", "-n", test_ns,
         "--for=condition=Ready", "pod/pvc-consumer",
         "--timeout=300s", quiet=True, check=False)

    # Web deployment
    web_yaml = """\
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
              memory: 256Mi"""
    subprocess.run(
        f"echo '{web_yaml}' | kubectl --context {ctx} apply -n {test_ns} -f -",
        shell=True, capture_output=True, text=True)

    kctl(ctx, "rollout", "status", "-n", test_ns, "deployment/web",
         "--timeout=300s", quiet=True, check=False)

    # Expose and create ingress
    subprocess.run(
        f"kubectl --context {ctx} expose deployment web -n {test_ns} "
        f"--port=80 --target-port=80 --type=ClusterIP --dry-run=client -o yaml "
        f"| kubectl --context {ctx} apply -f -",
        shell=True, capture_output=True, text=True)

    ingress_yaml = """\
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
                  number: 80"""
    subprocess.run(
        f"echo '{ingress_yaml}' | kubectl --context {ctx} apply -n {test_ns} -f -",
        shell=True, capture_output=True, text=True)

    # Wait for ingress endpoint
    ingress_addr = ""
    for _ in range(32):
        ingress_addr = kctl_output(
            ctx, "--request-timeout=15s", "-n", "ingress-nginx",
            "get", "svc", "ingress-nginx-controller",
            "-o", "jsonpath={.status.loadBalancer.ingress[0].hostname}"
                  "{.status.loadBalancer.ingress[0].ip}",
            check=False, quiet=True)
        if ingress_addr:
            break
        time.sleep(10)

    if not ingress_addr:
        print("WARNING: Ingress endpoint not assigned")

    # HTTP check
    http_code = ""
    if ingress_addr:
        for _ in range(18):
            http_code = run_output(
                ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                 "-H", "Host: web.local", f"http://{ingress_addr}/"],
                check=False, quiet=True)
            if http_code == "200":
                break
            time.sleep(5)
        if http_code != "200":
            print(f"WARNING: Ingress not reachable, status={http_code}")

    # Default storage class
    default_sc = kctl_output(
        ctx, "--request-timeout=20s", "get", "sc", "-o",
        "jsonpath={range .items[?(@.metadata.annotations.storageclass\\.kubernetes\\.io/is-default-class==\"true\")]}{.metadata.name}{\"\\n\"}{end}",
        check=False, quiet=True).split("\n")[0]

    # AWS-specific autoscaler checks
    if cloud == "aws":
        role_arn = kctl_output(
            ctx, "-n", "kube-system", "get", "sa", "cluster-autoscaler",
            "-o", "jsonpath={.metadata.annotations.eks\\.amazonaws\\.com/role-arn}",
            check=False, quiet=True)
        if not role_arn:
            print("WARNING: cluster-autoscaler SA missing IRSA annotation")

    # Full validation: autoscaler test
    if full_validation:
        print("\n--- Full Validation: Autoscaler test ---")
        initial_nodes = len(kctl_output(
            ctx, "get", "nodes", "--no-headers",
            check=False, quiet=True).strip().splitlines())

        burst_yaml = """\
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
              memory: "256Mi" """
        subprocess.run(
            f"echo '{burst_yaml}' | kubectl --context {ctx} apply -n {test_ns} -f -",
            shell=True, capture_output=True, text=True)

        scaled_up = False
        for _ in range(24):
            current = len(kctl_output(
                ctx, "get", "nodes", "--no-headers",
                check=False, quiet=True).strip().splitlines())
            if current > initial_nodes:
                scaled_up = True
                print(f"  Scale-up detected: {initial_nodes} -> {current}")
                break
            time.sleep(10)
        if not scaled_up:
            print("WARNING: Autoscaler scale-up not detected")

        kctl(ctx, "scale", "deployment", "autoscaler-burst", "-n", test_ns,
             "--replicas=0", quiet=True, check=False)

        scaled_down = False
        for _ in range(48):
            current = len(kctl_output(
                ctx, "get", "nodes", "--no-headers",
                check=False, quiet=True).strip().splitlines())
            if current <= initial_nodes:
                scaled_down = True
                print(f"  Scale-down detected: back to {current} nodes")
                break
            time.sleep(10)
        if not scaled_down:
            print("WARNING: Autoscaler scale-down not detected")

    # Cleanup test namespace
    kctl(ctx, "delete", "ns", test_ns, "--wait=false",
         check=False, quiet=True)

    print(f"Validation completed for {cluster_name} ({cloud})")
    return {
        "ingress_endpoint": ingress_addr,
        "default_storage_class": default_sc,
        "kube_context": ctx,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    args = parse_args()
    cloud = args.cloud
    name = args.name
    env_name = args.env_name
    region = args.region

    require_cmd("terraform")
    require_cmd("kubectl")
    require_cmd("helm")

    info = derive_cluster_info(cloud, name, env_name, region)
    cluster_name = info["cluster_name"]
    base_name = info["base_name"]

    print(f"Creating {cloud.upper()} cluster: {cluster_name} "
          f"in {region} (env={env_name})")

    with tempfile.TemporaryDirectory() as tmp:
        vars_file = os.path.join(tmp, "vars.tfvars")
        backend_file = os.path.join(tmp, "backend.hcl")

        write_tfvars(vars_file, cloud, info, env_name, region,
                     public_api=args.public_api)
        prepare_backend(cloud, cluster_name, env_name, region, info,
                        backend_file)

        tf_dir = ROOT_DIR / "terraform" / TF_STACK[cloud]
        os.chdir(tf_dir)

        terraform_init(cloud, backend_file)
        run(["terraform", "apply", "-auto-approve", "-input=false",
             f"-var-file={vars_file}"], timeout=1800)

        # Get autoscaler role ARN (AWS only)
        autoscaler_role_arn = ""
        if cloud == "aws":
            autoscaler_role_arn = terraform_output("cluster_autoscaler_role_arn")

    # Configure kubeconfig
    update_kubeconfig(cloud, cluster_name, region, info,
                      public_api=args.public_api)

    # Resolve context
    ctx = resolve_kube_context(cluster_name)
    if not ctx:
        print(f"ERROR: Unable to resolve kube context for: {cluster_name}")
        sys.exit(1)

    # Bootstrap
    bootstrap(cloud, cluster_name, region, env_name, ctx,
              autoscaler_role_arn=autoscaler_role_arn,
              public_api=args.public_api)

    # Validate
    result = validate(cloud, cluster_name, region, ctx,
                      full_validation=args.full_validation)

    # Summary
    k8s_ver = kctl_output(ctx, "version", "-o", "json", check=False,
                          quiet=True)
    try:
        ver = json.loads(k8s_ver)["serverVersion"]["gitVersion"]
    except (json.JSONDecodeError, KeyError):
        ver = "unknown"

    node_count = len(kctl_output(
        ctx, "get", "nodes", "--no-headers",
        check=False, quiet=True).strip().splitlines())

    print(f"\n{'='*60}")
    print(f"  Cluster name:      {cluster_name}")
    print(f"  Region:            {region}")
    print(f"  Kubernetes:        {ver}")
    print(f"  Nodes:             {node_count}")
    print(f"  Ingress endpoint:  {result.get('ingress_endpoint', 'N/A')}")
    print(f"  Storage class:     {result.get('default_storage_class', 'N/A')}")
    print(f"  Kube context:      {result.get('kube_context', 'N/A')}")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
