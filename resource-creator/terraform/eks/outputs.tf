output "cluster_names" {
  value = { for env, m in module.eks : env => m.cluster_name }
}

output "cluster_endpoints" {
  value = { for env, m in module.eks : env => m.cluster_endpoint }
}

output "cluster_autoscaler_role_arns" {
  value = { for env, m in module.irsa_cluster_autoscaler : env => m.iam_role_arn }
}

output "cluster_autoscaler_role_arn" {
  value = one([for m in values(module.irsa_cluster_autoscaler) : m.iam_role_arn])
}
