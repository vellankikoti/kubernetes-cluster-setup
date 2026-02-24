variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "cluster_version" {
  type    = string
  default = "1.34"
}

variable "environments" {
  type    = list(string)
  default = ["dev", "qa", "staging", "prod"]
}

variable "base_name" {
  type    = string
  default = "platform"
}

variable "master_authorized_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to access the GKE public control-plane endpoint"
  default     = []
}

variable "enable_private_endpoint" {
  type        = bool
  description = "Whether to expose only private endpoint for GKE control plane"
  default     = true
}

variable "tags" {
  type = map(string)
  default = {
    owner       = "platform-team"
    managed_by  = "terraform"
    cost_center = "k8s-shared"
    repo        = "resource-creator"
  }
}
