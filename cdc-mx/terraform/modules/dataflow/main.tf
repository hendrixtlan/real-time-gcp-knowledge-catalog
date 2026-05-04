# =============================================================================
# Module: dataflow
# Job de serving: GCS notifications → leer Avro → upsert AlloyDB
# Streaming engine activado para baja latencia.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.30"
    }
  }
}

# -----------------------------------------------------------------------------
# Service account dedicado
# -----------------------------------------------------------------------------
resource "google_service_account" "dataflow" {
  project      = var.project_id
  account_id   = "${var.prefix}-dataflow-sa"
  display_name = "Dataflow CDC serving"
}

resource "google_project_iam_member" "dataflow_worker" {
  project = var.project_id
  role    = "roles/dataflow.worker"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_project_iam_member" "dataflow_storage" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_project_iam_member" "dataflow_pubsub_pub" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_project_iam_member" "dataflow_pubsub_sub" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_project_iam_member" "dataflow_secret" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_project_iam_member" "dataflow_alloydb" {
  project = var.project_id
  role    = "roles/alloydb.client"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_project_iam_member" "dataflow_kms" {
  project = var.project_id
  role    = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

# -----------------------------------------------------------------------------
# Bucket temp/staging
# -----------------------------------------------------------------------------
resource "google_storage_bucket" "temp" {
  project                     = var.project_id
  name                        = "${var.project_id}-${var.prefix}-dataflow-temp"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true

  encryption {
    default_kms_key_name = var.kms_storage_key_id
  }

  lifecycle_rule {
    condition { age = 1 }
    action { type = "Delete" }
  }
}

# -----------------------------------------------------------------------------
# Flex template job: serving
# -----------------------------------------------------------------------------
resource "google_dataflow_flex_template_job" "serving" {
  provider                = google-beta
  project                 = var.project_id
  region                  = var.region
  name                    = "${var.prefix}-serving"
  container_spec_gcs_path = var.flex_template_gcs_path

  parameters = {
    gcs_notifications_subscription = "projects/${var.project_id}/subscriptions/${var.gcs_notifications_subscription}"
    cdc_events_topic               = "projects/${var.project_id}/topics/${var.cdc_events_topic}"
    dlq_topic                      = "projects/${var.project_id}/topics/${var.dlq_topic}"
    alloydb_writer_secret          = var.alloydb_writer_secret
    alloydb_password_secret        = var.alloydb_password_secret
    triggering_frequency_seconds   = "1"
    upsert_batch_size              = "100"
  }

  on_delete                = "drain"
  enable_streaming_engine  = true
  service_account_email    = google_service_account.dataflow.email
  network                  = var.vpc_name
  subnetwork               = "regions/${var.region}/subnetworks/${var.subnet_name}"
  ip_configuration         = "WORKER_IP_PRIVATE"
  temp_location            = "gs://${google_storage_bucket.temp.name}/temp"
  staging_location         = "gs://${google_storage_bucket.temp.name}/staging"
  machine_type             = var.machine_type
  max_workers              = var.max_workers
  num_workers              = var.num_workers

  labels = {
    pipeline    = "cdc-serving"
    environment = var.environment
    compliance  = "lfpdppp"
  }

  depends_on = [
    google_project_iam_member.dataflow_worker,
    google_project_iam_member.dataflow_alloydb,
    google_project_iam_member.dataflow_pubsub_sub,
    google_project_iam_member.dataflow_secret,
  ]
}
