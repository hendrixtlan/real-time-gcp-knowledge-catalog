# =============================================================================
# Module: alloydb
# Hot tier para lookups < 10ms. CMEK obligatorio desde inicio.
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

resource "google_alloydb_cluster" "main" {
  cluster_id = "${var.prefix}-cluster"
  location   = var.region
  project    = var.project_id

  network_config {
    network = var.vpc_id
  }

  initial_user {
    user     = "postgres"
    password = var.initial_password
  }

  # CMEK obligatorio (Art. 19 LFPDPPP)
  encryption_config {
    kms_key_name = var.kms_key_id
  }

  automated_backup_policy {
    enabled                = true
    backup_window          = "1800s"
    location               = var.region
    enabled                = true

    weekly_schedule {
      days_of_week = ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"]
      start_times {
        hours = 2
      }
    }

    quantity_based_retention {
      count = 14
    }

    encryption_config {
      kms_key_name = var.kms_key_id
    }
  }

  continuous_backup_config {
    enabled              = true
    recovery_window_days = 7

    encryption_config {
      kms_key_name = var.kms_key_id
    }
  }

  depends_on = [
    var.networking_dependency,
    var.kms_dependency,
  ]
}

# -----------------------------------------------------------------------------
# Primary instance — escrituras de Dataflow y aplicaciones
# -----------------------------------------------------------------------------
resource "google_alloydb_instance" "primary" {
  cluster       = google_alloydb_cluster.main.name
  instance_id   = "${var.prefix}-primary"
  instance_type = "PRIMARY"

  machine_config {
    cpu_count = var.primary_cpu_count
  }

  # Tuning para latencia baja
  database_flags = {
    "max_connections"                          = "2000"
    "max_parallel_workers"                     = tostring(var.primary_cpu_count * 2)
    "max_parallel_workers_per_gather"          = tostring(var.primary_cpu_count)
    "max_worker_processes"                     = tostring(var.primary_cpu_count * 4)
    "random_page_cost"                         = "1.1"
    "effective_io_concurrency"                 = "200"
    "work_mem"                                 = "65536"
    "maintenance_work_mem"                     = "2097152"
    "log_min_duration_statement"               = "100"
    "default_statistics_target"                = "500"
    "google_columnar_engine.enabled"           = "on"
    "google_columnar_engine.memory_size_in_mb" = "4096"
  }

  query_insights_config {
    query_string_length     = 1024
    record_application_tags = true
    record_client_address   = true
  }
}

# -----------------------------------------------------------------------------
# Read pool — lecturas de aplicación. La app DEBE conectarse aquí.
# -----------------------------------------------------------------------------
resource "google_alloydb_instance" "read_pool" {
  cluster       = google_alloydb_cluster.main.name
  instance_id   = "${var.prefix}-read-pool"
  instance_type = "READ_POOL"

  read_pool_config {
    node_count = var.read_pool_node_count
  }

  machine_config {
    cpu_count = var.read_pool_cpu_count
  }

  database_flags = {
    "max_connections"          = "2000"
    "random_page_cost"         = "1.1"
    "effective_io_concurrency" = "200"
    "work_mem"                 = "65536"
  }
}
