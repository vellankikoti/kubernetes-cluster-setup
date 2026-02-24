locals {
  env_config = {
    dev     = { cidr = "10.20.0.0/16", min = 1, desired = 1, max = 2 }
    qa      = { cidr = "10.21.0.0/16", min = 1, desired = 1, max = 2 }
    staging = { cidr = "10.22.0.0/16", min = 1, desired = 1, max = 3 }
    prod    = { cidr = "10.23.0.0/16", min = 2, desired = 2, max = 6 }
  }

  selected = { for e in var.environments : e => local.env_config[e] }
}

data "aws_caller_identity" "current" {}

moved {
  from = module.eks["dev"].aws_eks_addon.this["aws-ebs-csi-driver"]
  to   = aws_eks_addon.ebs_csi["dev"]
}

moved {
  from = module.eks["qa"].aws_eks_addon.this["aws-ebs-csi-driver"]
  to   = aws_eks_addon.ebs_csi["qa"]
}

moved {
  from = module.eks["staging"].aws_eks_addon.this["aws-ebs-csi-driver"]
  to   = aws_eks_addon.ebs_csi["staging"]
}

moved {
  from = module.eks["prod"].aws_eks_addon.this["aws-ebs-csi-driver"]
  to   = aws_eks_addon.ebs_csi["prod"]
}

moved {
  from = module.eks["dev"].aws_eks_addon.this["aws-efs-csi-driver"]
  to   = aws_eks_addon.efs_csi["dev"]
}

moved {
  from = module.eks["qa"].aws_eks_addon.this["aws-efs-csi-driver"]
  to   = aws_eks_addon.efs_csi["qa"]
}

moved {
  from = module.eks["staging"].aws_eks_addon.this["aws-efs-csi-driver"]
  to   = aws_eks_addon.efs_csi["staging"]
}

moved {
  from = module.eks["prod"].aws_eks_addon.this["aws-efs-csi-driver"]
  to   = aws_eks_addon.efs_csi["prod"]
}

module "vpc" {
  for_each = local.selected

  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.5"

  name = "${var.base_name}-${each.key}-vpc"
  cidr = each.value.cidr

  azs             = ["${var.region}a", "${var.region}b", "${var.region}c"]
  private_subnets = [for i in range(3) : cidrsubnet(each.value.cidr, 4, i)]
  public_subnets  = [for i in range(3) : cidrsubnet(each.value.cidr, 4, i + 8)]

  enable_nat_gateway   = true
  single_nat_gateway   = each.key != "prod"
  enable_dns_hostnames = true

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  tags = merge(var.tags, {
    env        = each.key
    account_id = data.aws_caller_identity.current.account_id
  })
}

module "eks" {
  for_each = local.selected

  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                             = "${var.base_name}-${each.key}-eks"
  cluster_version                          = var.cluster_version
  cluster_endpoint_private_access          = true
  cluster_endpoint_public_access           = false
  enable_cluster_creator_admin_permissions = true

  vpc_id                   = module.vpc[each.key].vpc_id
  subnet_ids               = module.vpc[each.key].private_subnets
  control_plane_subnet_ids = module.vpc[each.key].private_subnets

  create_kms_key                         = true
  cluster_encryption_config              = { resources = ["secrets"] }
  enable_irsa                            = true
  authentication_mode                    = "API_AND_CONFIG_MAP"
  cloudwatch_log_group_retention_in_days = each.key == "prod" ? 14 : 7

  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
  }

  eks_managed_node_groups = {
    on_demand = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"
      min_size       = each.value.min
      max_size       = each.value.max
      desired_size   = each.value.desired
      labels = {
        workload = "critical"
      }
      update_config = {
        max_unavailable_percentage = 25
      }
      tags = {
        "k8s.io/cluster-autoscaler/enabled"                          = "true"
        "k8s.io/cluster-autoscaler/${var.base_name}-${each.key}-eks" = "owned"
      }
    }

    spot = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3a.medium", "t3.medium"]
      capacity_type  = "SPOT"
      min_size       = each.key == "prod" ? 1 : 0
      max_size       = each.value.max
      desired_size   = each.key == "prod" ? 1 : 0
      taints = {
        spot = {
          key    = "spot"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
      labels = {
        workload = "stateless"
      }
      update_config = {
        max_unavailable_percentage = 25
      }
      tags = {
        "k8s.io/cluster-autoscaler/enabled"                          = "true"
        "k8s.io/cluster-autoscaler/${var.base_name}-${each.key}-eks" = "owned"
      }
    }
  }

  tags = merge(var.tags, {
    env        = each.key
    account_id = data.aws_caller_identity.current.account_id
  })
}

module "irsa_cluster_autoscaler" {
  for_each = local.selected

  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.50"

  role_name = "${var.base_name}-${each.key}-cluster-autoscaler"

  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_ids   = [module.eks[each.key].cluster_name]

  oidc_providers = {
    main = {
      provider_arn               = module.eks[each.key].oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }

  tags = merge(var.tags, {
    env        = each.key
    account_id = data.aws_caller_identity.current.account_id
  })
}

module "irsa_ebs_csi" {
  for_each = local.selected

  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.50"

  role_name = "${var.base_name}-${each.key}-ebs-csi"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks[each.key].oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = merge(var.tags, {
    env        = each.key
    account_id = data.aws_caller_identity.current.account_id
  })
}

module "irsa_efs_csi" {
  for_each = local.selected

  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.50"

  role_name = "${var.base_name}-${each.key}-efs-csi"

  attach_efs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks[each.key].oidc_provider_arn
      namespace_service_accounts = ["kube-system:efs-csi-controller-sa"]
    }
  }

  tags = merge(var.tags, {
    env        = each.key
    account_id = data.aws_caller_identity.current.account_id
  })
}

data "aws_eks_addon_version" "ebs_csi" {
  for_each           = local.selected
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = var.cluster_version
  most_recent        = true
}

data "aws_eks_addon_version" "efs_csi" {
  for_each           = local.selected
  addon_name         = "aws-efs-csi-driver"
  kubernetes_version = var.cluster_version
  most_recent        = true
}

resource "aws_eks_addon" "ebs_csi" {
  for_each                    = local.selected
  cluster_name                = module.eks[each.key].cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = data.aws_eks_addon_version.ebs_csi[each.key].version
  service_account_role_arn    = module.irsa_ebs_csi[each.key].iam_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  timeouts {
    create = "45m"
    update = "45m"
    delete = "30m"
  }

  depends_on = [module.irsa_ebs_csi, module.eks]
}

resource "aws_eks_addon" "efs_csi" {
  for_each                    = local.selected
  cluster_name                = module.eks[each.key].cluster_name
  addon_name                  = "aws-efs-csi-driver"
  addon_version               = data.aws_eks_addon_version.efs_csi[each.key].version
  service_account_role_arn    = module.irsa_efs_csi[each.key].iam_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  timeouts {
    create = "45m"
    update = "45m"
    delete = "30m"
  }

  depends_on = [module.irsa_efs_csi, module.eks]
}
