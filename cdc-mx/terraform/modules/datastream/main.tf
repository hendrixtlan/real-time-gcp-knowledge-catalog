# =============================================================================
# Module: datastream
# Datastream con DOS streams paralelos:
#   1. Oracle → BigQuery (sink directo, 5-30s lag, para analítica)
#   2. Oracle → GCS landing (5MB/15s rotation, para path a AlloyDB)
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
# Connection profile: Oracle source
# -----------------------------------------------------------------------------
data "google_secret_manager_secret_version" "oracle_password" {
  secret = var.oracle_password_secret_id
}

resource "google_datastream_connection_profile" "oracle" {
  display_name          = "${var.prefix}-oracle-src"
  location              = var.region
  connection_profile_id = "${var.prefix}-oracle-src"

  oracle_profile {
    hostname         = var.oracle_host
    port             = var.oracle_port
    username         = var.oracle_user
    password         = data.google_secret_manager_secret_version.oracle_password.secret_data
    database_service = var.oracle_service_name
  }

  private_connectivity {
    private_connection = var.private_connection_id
  }
}

# -----------------------------------------------------------------------------
# Connection profile: BigQuery sink (directo, con MERGE automático)
# -----------------------------------------------------------------------------
resource "google_datastream_connection_profile" "bigquery" {
  display_name          = "${var.prefix}-bq-dest"
  location              = var.region
  connection_profile_id = "${var.prefix}-bq-dest"

  bigquery_profile {}
}

# -----------------------------------------------------------------------------
# GCS bucket para landing intermedio (path a AlloyDB)
# -----------------------------------------------------------------------------
resource "google_storage_bucket" "landing" {
  project                     = var.project_id
  name                        = "${var.project_id}-${var.prefix}-landing"
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true

  encryption {
    default_kms_key_name = var.kms_storage_key_id
  }

  lifecycle_rule {
    condition { age = 7 }
    action { type = "Delete" }
  }

  versioning {
    enabled = false
  }

  depends_on = [var.kms_storage_dependency]
}

# Notificación a Pub/Sub cuando hay archivo nuevo
resource "google_storage_notification" "landing" {
  bucket         = google_storage_bucket.landing.name
  payload_format = "JSON_API_V1"
  topic          = var.gcs_notification_topic_id
  event_types    = ["OBJECT_FINALIZE"]
}

resource "google_datastream_connection_profile" "gcs" {
  display_name          = "${var.prefix}-gcs-dest"
  location              = var.region
  connection_profile_id = "${var.prefix}-gcs-dest"

  gcs_profile {
    bucket    = google_storage_bucket.landing.name
    root_path = "/cdc"
  }
}

# -----------------------------------------------------------------------------
# Stream 1: Oracle → BigQuery (analítica, sink directo CDC)
# -----------------------------------------------------------------------------
resource "google_datastream_stream" "oracle_to_bq" {
  display_name = "${var.prefix}-oracle-to-bq"
  location     = var.region
  stream_id    = "${var.prefix}-oracle-to-bq"

  source_config {
    source_connection_profile = google_datastream_connection_profile.oracle.id

    oracle_source_config {
      include_objects {
        dynamic "oracle_schemas" {
          for_each = distinct([for t in var.tables : t.schema])
          content {
            schema = oracle_schemas.value
            oracle_tables {
              dynamic "oracle_tables" {
                for_each = [for t in var.tables : t if t.schema == oracle_schemas.value]
                content {
                  table = oracle_tables.value.table
                }
              }
            }
          }
        }
      }

      max_concurrent_cdc_tasks      = 5
      max_concurrent_backfill_tasks = 12
    }
  }

  destination_config {
    destination_connection_profile = google_datastream_connection_profile.bigquery.id

    bigquery_destination_config {
      data_freshness = "60s"  # MERGE cada 60s

      single_target_dataset {
        dataset_id = "${var.project_id}:${var.bq_analytics_dataset}"
      }
    }
  }

  backfill_all {}

  desired_state = "RUNNING"
}

# -----------------------------------------------------------------------------
# Stream 2: Oracle → GCS (para path serving con baja latencia)
# -----------------------------------------------------------------------------
resource "google_datastream_stream" "oracle_to_gcs" {
  display_name = "${var.prefix}-oracle-to-gcs"
  location     = var.region
  stream_id    = "${var.prefix}-oracle-to-gcs"

  source_config {
    source_connection_profile = google_datastream_connection_profile.oracle.id

    oracle_source_config {
      include_objects {
        dynamic "oracle_schemas" {
          for_each = distinct([for t in var.tables : t.schema])
          content {
            schema = oracle_schemas.value
            oracle_tables {
              dynamic "oracle_tables" {
                for_each = [for t in var.tables : t if t.schema == oracle_schemas.value]
                content {
                  table = oracle_tables.value.table
                }
              }
            }
          }
        }
      }

      max_concurrent_cdc_tasks      = 5
      max_concurrent_backfill_tasks = 12
    }
  }

  destination_config {
    destination_connection_profile = google_datastream_connection_profile.gcs.id

    gcs_destination_config {
      path                   = "/cdc"
      file_rotation_mb       = 5    # ← optimización para latencia
      file_rotation_interval = "15s" # ← optimización para latencia

      avro_file_format {}
    }
  }

  backfill_all {}

  desired_state = "RUNNING"
}
