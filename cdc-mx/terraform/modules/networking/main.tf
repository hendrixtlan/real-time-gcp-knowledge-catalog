# =============================================================================
# Module: networking
# VPC con subnets dedicadas por servicio. Todo en northamerica-south1.
# Sin IPs públicas en data plane. Cloud NAT solo para Dataflow workers.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
  }
}

resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "${var.prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  description             = "VPC para stack CDC en cumplimiento LFPDPPP"
}

# Subnet primaria: Cloud Run, AlloyDB, servicios generales
resource "google_compute_subnetwork" "primary" {
  project                  = var.project_id
  name                     = "${var.prefix}-subnet-primary"
  network                  = google_compute_network.vpc.id
  region                   = var.region
  ip_cidr_range            = "10.10.0.0/20"
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Subnet dedicada para Dataflow workers
resource "google_compute_subnetwork" "dataflow" {
  project                  = var.project_id
  name                     = "${var.prefix}-subnet-dataflow"
  network                  = google_compute_network.vpc.id
  region                   = var.region
  ip_cidr_range            = "10.10.16.0/20"
  private_ip_google_access = true
}

# Subnet pequeña para Datastream private connection
# Datastream requiere /29 dedicado para peering
resource "google_compute_subnetwork" "datastream" {
  project                  = var.project_id
  name                     = "${var.prefix}-subnet-datastream"
  network                  = google_compute_network.vpc.id
  region                   = var.region
  ip_cidr_range            = "10.10.32.0/29"
  private_ip_google_access = true
}

# Subnet para conector VPC Serverless (Cloud Run → VPC)
resource "google_compute_subnetwork" "serverless_connector" {
  project                  = var.project_id
  name                     = "${var.prefix}-subnet-connector"
  network                  = google_compute_network.vpc.id
  region                   = var.region
  ip_cidr_range            = "10.10.48.0/28"
  private_ip_google_access = true
}

# =============================================================================
# Service Networking peering (requerido para AlloyDB con private IP)
# =============================================================================
resource "google_compute_global_address" "alloydb_range" {
  project       = var.project_id
  name          = "${var.prefix}-alloydb-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "alloydb_peering" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.alloydb_range.name]
}

# =============================================================================
# Cloud NAT — solo para Dataflow workers (necesitan PyPI durante setup)
# Si la imagen Docker incluye todas las deps, considera eliminar este NAT.
# =============================================================================
resource "google_compute_router" "nat" {
  project = var.project_id
  name    = "${var.prefix}-nat-router"
  network = google_compute_network.vpc.id
  region  = var.region
}

resource "google_compute_router_nat" "nat" {
  project                            = var.project_id
  name                               = "${var.prefix}-nat"
  router                             = google_compute_router.nat.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.dataflow.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# =============================================================================
# VPC Connector para Cloud Run
# =============================================================================
resource "google_vpc_access_connector" "main" {
  project        = var.project_id
  name           = "${var.prefix}-connector"
  region         = var.region
  subnet {
    name = google_compute_subnetwork.serverless_connector.name
  }
  machine_type   = "e2-micro"
  min_instances  = 2
  max_instances  = 10
}

# =============================================================================
# Firewall — interno permisivo, externo restrictivo
# =============================================================================
resource "google_compute_firewall" "internal" {
  project       = var.project_id
  name          = "${var.prefix}-allow-internal"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  source_ranges = ["10.10.0.0/16"]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

resource "google_compute_firewall" "iap_ssh" {
  project       = var.project_id
  name          = "${var.prefix}-allow-iap-ssh"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]  # IAP

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  target_tags = ["iap-ssh"]
}

# Datastream → Oracle reverse proxy (si usas reverse proxy)
# Si Oracle es accesible directo via Cloud Interconnect, omitir
resource "google_compute_firewall" "datastream_to_proxy" {
  project       = var.project_id
  name          = "${var.prefix}-allow-datastream-proxy"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  source_ranges = ["10.10.32.0/29"]
  target_tags   = ["datastream-proxy"]

  allow {
    protocol = "tcp"
    ports    = ["1521"]
  }
}

# =============================================================================
# Datastream Private Connection
# =============================================================================
resource "google_datastream_private_connection" "oracle" {
  display_name          = "${var.prefix}-oracle-pc"
  location              = var.region
  private_connection_id = "${var.prefix}-oracle-pc"

  vpc_peering_config {
    vpc    = google_compute_network.vpc.id
    subnet = "10.10.32.0/29"
  }

  depends_on = [google_compute_subnetwork.datastream]
}
