locals {
  env_config = {
    dev     = { cidr = "10.30.0.0/20", min = 1, max = 6 }
    qa      = { cidr = "10.31.0.0/20", min = 1, max = 6 }
    staging = { cidr = "10.32.0.0/20", min = 2, max = 10 }
    prod    = { cidr = "10.33.0.0/20", min = 3, max = 30 }
  }
  selected = { for e in var.environments : e => local.env_config[e] }

  required_services = toset([
    "container.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com"
  ])
}

data "google_client_config" "current" {}

resource "google_project_service" "required" {
  for_each                   = local.required_services
  project                    = var.project_id
  service                    = each.value
  disable_dependent_services = true
}

resource "google_compute_network" "vpc" {
  for_each                = local.selected
  name                    = "${var.base_name}-${each.key}-gke-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  for_each      = local.selected
  name          = "${var.base_name}-${each.key}-gke-subnet"
  network       = google_compute_network.vpc[each.key].id
  ip_cidr_range = each.value.cidr
  region        = var.region

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = cidrsubnet(each.value.cidr, 4, 8)
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = cidrsubnet(each.value.cidr, 4, 9)
  }
}

resource "google_compute_router" "router" {
  for_each = local.selected
  name     = "${var.base_name}-${each.key}-router"
  region   = var.region
  network  = google_compute_network.vpc[each.key].id
}

resource "google_compute_router_nat" "nat" {
  for_each                           = local.selected
  name                               = "${var.base_name}-${each.key}-nat"
  router                             = google_compute_router.router[each.key].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_container_cluster" "gke" {
  provider                 = google-beta
  for_each                 = local.selected
  name                     = "${var.base_name}-${each.key}-gke"
  location                 = var.region
  network                  = google_compute_network.vpc[each.key].name
  subnetwork               = google_compute_subnetwork.subnet[each.key].name
  remove_default_node_pool = true
  initial_node_count       = 1
  min_master_version       = var.cluster_version
  logging_service          = "logging.googleapis.com/kubernetes"
  monitoring_service       = "monitoring.googleapis.com/kubernetes"
  deletion_protection      = each.key == "prod"

  release_channel {
    channel = each.key == "prod" ? "REGULAR" : "STABLE"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = var.enable_private_endpoint
    master_ipv4_cidr_block  = cidrsubnet(each.value.cidr, 4, 10)
  }

  dynamic "master_authorized_networks_config" {
    for_each = length(var.master_authorized_cidrs) > 0 ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.master_authorized_cidrs
        content {
          cidr_block   = cidr_blocks.value
          display_name = "authorized-${replace(cidr_blocks.value, "/", "-")}"
        }
      }
    }
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  resource_labels = merge(var.tags, { env = each.key, gcp_project = data.google_client_config.current.project })

  depends_on = [google_project_service.required]
}

resource "google_container_node_pool" "ondemand" {
  for_each           = local.selected
  cluster            = google_container_cluster.gke[each.key].name
  location           = var.region
  name               = "ondemand"
  version            = var.cluster_version
  initial_node_count = each.value.min

  autoscaling {
    min_node_count = each.value.min
    max_node_count = each.value.max
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = each.key == "prod" ? "e2-standard-4" : "e2-standard-2"
    image_type   = "COS_CONTAINERD"
    disk_size_gb = 100
    disk_type    = "pd-balanced"
    spot         = false
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    labels = {
      workload = "critical"
    }
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

resource "google_container_node_pool" "spot" {
  for_each           = local.selected
  cluster            = google_container_cluster.gke[each.key].name
  location           = var.region
  name               = "spot"
  version            = var.cluster_version
  initial_node_count = 1

  autoscaling {
    min_node_count = each.key == "prod" ? 2 : 1
    max_node_count = each.value.max * 2
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = "t2a-standard-4"
    image_type   = "COS_CONTAINERD"
    disk_size_gb = 100
    disk_type    = "pd-balanced"
    spot         = true
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    labels = {
      workload = "stateless"
    }
    taint {
      key    = "spot"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
