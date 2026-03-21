variable "host_kubeconfig" {
  type        = string
  description = "Kubeconfig path for host cluster"
  default     = "~/.kube/config"
}

variable "host_kube_context" {
  type        = string
  description = "Kube context to use on the host cluster (empty = current context)"
  default     = ""
}

variable "environments" {
  type    = list(string)
  default = ["dev", "qa", "staging", "prod"]
}

variable "vcluster_chart_version" {
  type    = string
  default = "0.25.0"
}

variable "cluster_version" {
  type        = string
  description = "Kubernetes version for the virtual cluster"
  default     = "1.34"
}
