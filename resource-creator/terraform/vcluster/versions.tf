terraform {
  required_version = ">= 1.7.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.32"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
  }
}

provider "kubernetes" {
  config_path = pathexpand(var.host_kubeconfig)
}

provider "helm" {
  kubernetes {
    config_path = pathexpand(var.host_kubeconfig)
  }
}
