output "vcluster_names" {
  value = [for k, _ in helm_release.vcluster : k]
}
