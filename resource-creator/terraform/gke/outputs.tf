output "cluster_names" {
  value = { for env, c in google_container_cluster.gke : env => c.name }
}
