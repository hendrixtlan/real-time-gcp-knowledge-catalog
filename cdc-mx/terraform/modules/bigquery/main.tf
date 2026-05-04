# =============================================================================
# Module: bigquery
# Datasets con CMEK. Las tablas las gestiona Datastream automáticamente.
# Las vistas y configuración adicional se aplican vía bigquery/setup.sql.
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

data "google_project" "current" {
  project_id = var.project_id
}

resource "google_bigquery_dataset" "analytics" {
  project       = var.project_id
  dataset_id    = "analytics"
  location      = var.region
  friendly_name = "Analytics — tablas finales con CDC aplicado"

  default_encryption_configuration {
    kms_key_name = var.kms_bigquery_key_id
  }

  # Datastream service agent necesita poder escribir aquí
  access {
    role          = "roles/bigquery.dataEditor"
    user_by_email = "service-${data.google_project.current.number}@gcp-sa-datastream.iam.gserviceaccount.com"
  }

  access {
    role          = "OWNER"
    special_group = "projectOwners"
  }

  access {
    role          = "READER"
    special_group = "projectReaders"
  }

  delete_contents_on_destroy = false
  depends_on                 = [var.kms_dependency]
}

resource "google_bigquery_dataset" "ops" {
  project       = var.project_id
  dataset_id    = "ops"
  location      = var.region
  friendly_name = "Ops — métricas internas, lag CDC, reconciliación"

  default_encryption_configuration {
    kms_key_name = var.kms_bigquery_key_id
  }

  default_partition_expiration_ms = 7776000000  # 90 días

  delete_contents_on_destroy = true
  depends_on                 = [var.kms_dependency]
}

# Tabla de métricas de lag end-to-end
resource "google_bigquery_table" "cdc_lag" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.ops.dataset_id
  table_id   = "cdc_lag"

  encryption_configuration {
    kms_key_name = var.kms_bigquery_key_id
  }

  time_partitioning {
    type          = "DAY"
    field         = "received_at"
    expiration_ms = 7776000000
  }

  schema = jsonencode([
    { name = "table_name", type = "STRING", mode = "REQUIRED" },
    { name = "sink", type = "STRING", mode = "REQUIRED",
      description = "alloydb | bigquery" },
    { name = "cdc_op_ts", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "received_at", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "lag_ms", type = "INT64", mode = "REQUIRED" },
  ])

  deletion_protection = false
}

# Tabla de auditoría de derechos ARCO (mirror de AlloyDB para análisis)
resource "google_bigquery_table" "arco_audit" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.ops.dataset_id
  table_id   = "arco_audit"

  encryption_configuration {
    kms_key_name = var.kms_bigquery_key_id
  }

  time_partitioning {
    type  = "DAY"
    field = "submitted_at"
  }

  clustering = ["request_type", "resolution"]

  schema = jsonencode([
    { name = "request_id", type = "INT64", mode = "REQUIRED" },
    { name = "titular_id_hash", type = "STRING", mode = "REQUIRED",
      description = "SHA-256 del titular_id - no PII directo" },
    { name = "request_type", type = "STRING", mode = "REQUIRED" },
    { name = "submitted_at", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "resolved_at", type = "TIMESTAMP" },
    { name = "resolution", type = "STRING" },
    { name = "sla_hours_used", type = "FLOAT64" },
    { name = "deadline_breached", type = "BOOL" },
  ])

  deletion_protection = false
}
