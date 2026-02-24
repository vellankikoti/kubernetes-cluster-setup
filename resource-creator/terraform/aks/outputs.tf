output "cluster_names" {
  value = { for env, c in azurerm_kubernetes_cluster.aks : env => c.name }
}
