variable "environment" {
  type = string
}

variable "base_tags" {
  type = map(string)
}

locals {
  tags = merge(var.base_tags, {
    environment = var.environment
    managed_by  = "terraform"
  })
}

output "tags" {
  value = local.tags
}
