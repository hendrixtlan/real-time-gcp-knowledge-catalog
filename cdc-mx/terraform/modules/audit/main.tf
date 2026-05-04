# =============================================================================
# Module: audit
# Cloud Audit Logs Data Access habilitados a nivel proyecto.
# Sink dedicado a bucket GCS inmutable con retención de 5 años.
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

# -----------------------------------------------------------------------------
# Data Access logs habilitados a nivel proyecto
# -----------------------------------------------------------------------------
resource "google_project_iam_audit_config" "data_access" {
  project = var.project_id
  service = "allServices"

  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
  audit_log_config {
    log_type = "ADMIN_READ"
  }
}

# -----------------------------------------------------------------------------
# Bucket de archivo inmutable
# -----------------------------------------------------------------------------
resource "google_storage_bucket" "audit_archive" {
  project                     = var.project_id
  name                        = "${var.project_id}-${var.prefix}-audit-archive"
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true

  retention_policy {
    retention_period = 157680000  # 5 años
    is_locked        = false      # cuando esté validado, cambiar a true
  }

  encryption {
    default_kms_key_name = var.kms_storage_key_id
  }

  versioning {
    enabled = true
  }

  storage_class = "COLDLINE"  # más barato para acceso poco frecuente

  lifecycle_rule {
    condition { age = 1825 }  # 5 años
    action { type = "Delete" }
  }
}

# -----------------------------------------------------------------------------
# Log sink: filtra solo eventos relevantes para LFPDPPP
# -----------------------------------------------------------------------------
resource "google_logging_project_sink" "audit_archive" {
  project     = var.project_id
  name        = "${var.prefix}-audit-archive-sink"
  destination = "storage.googleapis.com/${google_storage_bucket.audit_archive.name}"

  filter = <<-EOT
    logName:"cloudaudit.googleapis.com" AND
    (
      resource.type="bigquery_resource"
      OR resource.type="alloydb_database"
      OR resource.type="audited_resource"
      OR resource.type="pubsub_topic"
      OR resource.type="pubsub_subscription"
      OR resource.type="gcs_bucket"
      OR resource.type="cloud_run_revision"
      OR resource.type="datastream.googleapis.com/Stream"
      OR resource.type="dataflow_job"
    )
  EOT

  unique_writer_identity = true
}

resource "google_storage_bucket_iam_member" "sink_writer" {
  bucket = google_storage_bucket.audit_archive.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.audit_archive.writer_identity
}

# -----------------------------------------------------------------------------
# Custom log metric: lag CDC end-to-end
# -----------------------------------------------------------------------------
resource "google_logging_metric" "cdc_e2e_lag" {
  project = var.project_id
  name    = "${var.prefix}/cdc_e2e_lag_ms"
  filter  = "resource.type=\"dataflow_job\" AND jsonPayload.metric=\"e2e_lag_ms\""

  metric_descriptor {
    metric_kind = "GAUGE"
    value_type  = "INT64"
    unit        = "ms"

    labels {
      key         = "table_name"
      value_type  = "STRING"
      description = "Nombre de la tabla Oracle"
    }
  }

  value_extractor = "EXTRACT(jsonPayload.lag_ms)"

  label_extractors = {
    table_name = "EXTRACT(jsonPayload.table_name)"
  }
}
