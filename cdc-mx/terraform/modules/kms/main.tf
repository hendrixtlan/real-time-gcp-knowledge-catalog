# =============================================================================
# Module: kms
# Cuatro llaves CMEK separadas para cumplir Art. 19 LFPDPPP.
# Llaves separadas permiten revocar acceso a un servicio sin afectar otros.
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

resource "google_kms_key_ring" "main" {
  project  = var.project_id
  name     = "${var.prefix}-keyring"
  location = var.region
}

# -----------------------------------------------------------------------------
# Llaves
# -----------------------------------------------------------------------------
locals {
  key_purposes = {
    bigquery = "Llave CMEK para BigQuery datasets con datos personales"
    alloydb  = "Llave CMEK para AlloyDB cluster (hot tier)"
    storage  = "Llave CMEK para Cloud Storage buckets (landing + audit)"
    pubsub   = "Llave CMEK para Pub/Sub topics con eventos CDC"
  }
}

resource "google_kms_crypto_key" "keys" {
  for_each = local.key_purposes

  name     = "${each.key}-cmek"
  key_ring = google_kms_key_ring.main.id
  purpose  = "ENCRYPT_DECRYPT"

  rotation_period = "7776000s"  # 90 días

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = var.protection_level
  }

  labels = {
    purpose     = each.key
    compliance  = "lfpdppp"
    environment = var.environment
  }

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# IAM bindings — cada service agent puede usar SU llave únicamente
# -----------------------------------------------------------------------------
data "google_project" "current" {
  project_id = var.project_id
}

# BigQuery service agent
resource "google_kms_crypto_key_iam_member" "bigquery" {
  crypto_key_id = google_kms_crypto_key.keys["bigquery"].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:bq-${data.google_project.current.number}@bigquery-encryption.iam.gserviceaccount.com"
}

# AlloyDB service agent
resource "google_kms_crypto_key_iam_member" "alloydb" {
  crypto_key_id = google_kms_crypto_key.keys["alloydb"].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-alloydb.iam.gserviceaccount.com"
}

# GCS service agent
resource "google_kms_crypto_key_iam_member" "storage" {
  crypto_key_id = google_kms_crypto_key.keys["storage"].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.current.number}@gs-project-accounts.iam.gserviceaccount.com"
}

# Pub/Sub service agent
resource "google_kms_crypto_key_iam_member" "pubsub" {
  crypto_key_id = google_kms_crypto_key.keys["pubsub"].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}
