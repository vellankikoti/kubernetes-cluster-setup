variable "subscription_id" {
  type = string
}

variable "region" {
  type    = string
  default = "eastus"
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

variable "tags" {
  type = map(string)
  default = {
    owner       = "platform-team"
    managed_by  = "terraform"
    cost_center = "k8s-shared"
    repo        = "resource-creator"
  }
}
