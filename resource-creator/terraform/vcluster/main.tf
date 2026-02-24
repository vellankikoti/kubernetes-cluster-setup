resource "kubernetes_namespace" "vcluster" {
  for_each = toset(var.environments)
  metadata {
    name = "vcluster-${each.value}"
    labels = {
      env = each.value
    }
  }
}

resource "helm_release" "vcluster" {
  for_each         = toset(var.environments)
  name             = "vcluster-${each.value}"
  namespace        = kubernetes_namespace.vcluster[each.value].metadata[0].name
  repository       = "https://charts.loft.sh"
  chart            = "vcluster"
  version          = var.vcluster_chart_version
  create_namespace = false
  wait             = true

  values = [
    yamlencode({
      sync = {
        toHost = {
          services = {
            enabled = true
          }
          ingresses = {
            enabled = true
          }
        }
      }
      controlPlane = {
        backingStore = {
          etcd = {
            deploy = {
              enabled = true
            }
          }
        }
        distro = {
          k8s = {
            version = "v1.34.1"
          }
        }
      }
    })
  ]
}
