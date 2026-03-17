variable "region" {
  type        = string
  description = "AWS region"
  default     = "us-east-1"
}

variable "cluster_version" {
  type        = string
  description = "EKS Kubernetes version"
  default     = "1.34"
}

variable "environments" {
  type        = list(string)
  description = "Environments to provision"
  default     = ["dev", "qa", "staging", "prod"]
}

variable "base_name" {
  type        = string
  default     = "platform"
  description = "Cluster name prefix"
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

variable "cluster_endpoint_public_access" {
  type        = bool
  description = "Enable public access to the EKS Kubernetes API endpoint"
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  type        = list(string)
  description = "List of CIDR blocks which can access the Amazon EKS public API server endpoint"
  default     = ["0.0.0.0/0"]
}
