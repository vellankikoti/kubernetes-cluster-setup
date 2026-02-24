variable "host_kubeconfig" {
  type        = string
  description = "Kubeconfig path for host cluster"
  default     = "~/.kube/config"
}

variable "environments" {
  type    = list(string)
  default = ["dev", "qa", "staging", "prod"]
}

variable "vcluster_chart_version" {
  type    = string
  default = "0.25.0"
}
