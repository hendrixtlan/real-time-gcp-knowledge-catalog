# =============================================================================
# Module: arco
# Servicio Cloud Run para derechos ARCO (Art. 22 LFPDPPP).
# Cloud Scheduler verifica SLA cada 4h.
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

resource "google_service_account" "arco" {
  project      = var.project_id
  account_id   = "${var.prefix}-arco-sa"
  display_name = "ARCO service (LFPDPPP Art. 22)"
}

# Permisos
resource "google_project_iam_member" "alloydb" {
  project = var.project_id
  role    = "roles/alloydb.client"
  member  = "serviceAccount:${google_service_account.arco.email}"
}

resource "google_project_iam_member" "bq_editor" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.arco.email}"
}

resource "google_project_iam_member" "bq_jobs" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.arco.email}"
}

resource "google_project_iam_member" "dlp_user" {
  project = var.project_id
  role    = "roles/dlp.user"
  member  = "serviceAccount:${google_service_account.arco.email}"
}

resource "google_project_iam_member" "secrets" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.arco.email}"
}

resource "google_project_iam_member" "pubsub_pub" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.arco.email}"
}

resource "google_project_iam_member" "kms" {
  project = var.project_id
  role    = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member  = "serviceAccount:${google_service_account.arco.email}"
}

# -----------------------------------------------------------------------------
# Bucket para exports de derecho de acceso (signed URLs, 7 días)
# -----------------------------------------------------------------------------
resource "google_storage_bucket" "arco_exports" {
  project                     = var.project_id
  name                        = "${var.project_id}-${var.prefix}-arco-exports"
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true

  encryption {
    default_kms_key_name = var.kms_storage_key_id
  }

  lifecycle_rule {
    condition { age = 30 }
    action { type = "Delete" }
  }
}

resource "google_storage_bucket_iam_member" "arco_exports_writer" {
  bucket = google_storage_bucket.arco_exports.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.arco.email}"
}

# -----------------------------------------------------------------------------
# Cloud Run service
# -----------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "arco" {
  project  = var.project_id
  name     = "${var.prefix}-arco"
  location = var.region

  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account = google_service_account.arco.email

    vpc_access {
      connector = var.vpc_connector_id
      egress    = "ALL_TRAFFIC"
    }

    containers {
      image = var.image_uri

      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "REGION"
        value = var.region
      }
      env {
        name  = "BQ_DATASET"
        value = var.bq_analytics_dataset
      }
      env {
        name  = "BQ_OPS_DATASET"
        value = var.bq_ops_dataset
      }
      env {
        name  = "EXPORT_BUCKET"
        value = google_storage_bucket.arco_exports.name
      }
      env {
        name  = "BREACH_TOPIC"
        value = var.breach_events_topic
      }
      env {
        name  = "ALLOYDB_CONN_SECRET"
        value = var.alloydb_writer_secret
      }
      env {
        name  = "ALLOYDB_PASSWORD_SECRET"
        value = var.alloydb_password_secret
      }
      env {
        name  = "DLP_DEIDENTIFY_TEMPLATE"
        value = var.dlp_deidentify_template
      }
      env {
        name  = "DLP_INSPECT_TEMPLATE"
        value = var.dlp_inspect_template
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
      }
    }

    scaling {
      min_instance_count = 0
      max_instance_count = 5
    }

    timeout = "300s"
  }

  depends_on = [
    google_project_iam_member.alloydb,
    google_project_iam_member.secrets,
  ]
}

# -----------------------------------------------------------------------------
# Cloud Scheduler — SLA check cada 4h
# -----------------------------------------------------------------------------
resource "google_service_account" "scheduler_invoker" {
  project      = var.project_id
  account_id   = "${var.prefix}-arco-scheduler"
  display_name = "Scheduler invoker for ARCO SLA check"
}

resource "google_cloud_run_v2_service_iam_member" "scheduler_invoker" {
  project  = var.project_id
  location = google_cloud_run_v2_service.arco.location
  name     = google_cloud_run_v2_service.arco.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler_invoker.email}"
}

resource "google_cloud_scheduler_job" "sla_check" {
  project     = var.project_id
  region      = var.region
  name        = "${var.prefix}-arco-sla-check"
  description = "Verificación de SLA Art. 22 LFPDPPP cada 4 horas"
  schedule    = "0 */4 * * *"
  time_zone   = "America/Mexico_City"

  http_target {
    http_method = "POST"
    uri         = "${google_cloud_run_v2_service.arco.uri}/arco/sla-check"

    oidc_token {
      service_account_email = google_service_account.scheduler_invoker.email
      audience              = google_cloud_run_v2_service.arco.uri
    }
  }
}
