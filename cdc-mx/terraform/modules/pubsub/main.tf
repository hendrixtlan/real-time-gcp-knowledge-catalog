# =============================================================================
# Module: pubsub
# Topics y subscriptions con CMEK y ordering.
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

# -----------------------------------------------------------------------------
# Topic: notificaciones de GCS (Datastream → archivos nuevos)
# -----------------------------------------------------------------------------
resource "google_pubsub_topic" "gcs_notifications" {
  project = var.project_id
  name    = "${var.prefix}-gcs-notifications"

  kms_key_name = var.kms_pubsub_key_id

  message_retention_duration = "86400s"  # 1 día (estos son notif, no CDC events)

  message_storage_policy {
    allowed_persistence_regions = [var.region]
  }

  depends_on = [var.kms_pubsub_dependency]
}

# Permiso para que GCS publique aquí
data "google_storage_project_service_account" "gcs" {
  project = var.project_id
}

resource "google_pubsub_topic_iam_member" "gcs_publisher" {
  topic  = google_pubsub_topic.gcs_notifications.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

# Subscription para Dataflow
resource "google_pubsub_subscription" "gcs_notifications_sub" {
  project = var.project_id
  name    = "${var.prefix}-gcs-notifications-sub"
  topic   = google_pubsub_topic.gcs_notifications.name

  ack_deadline_seconds       = 60
  message_retention_duration = "86400s"

  retry_policy {
    minimum_backoff = "1s"
    maximum_backoff = "60s"
  }
}

# -----------------------------------------------------------------------------
# Topic: CDC events normalizados (output de Dataflow después de procesar Avro)
# Usado para fan-out a otros consumidores y replay
# -----------------------------------------------------------------------------
resource "google_pubsub_topic" "cdc_events" {
  project = var.project_id
  name    = "${var.prefix}-cdc-events"

  kms_key_name = var.kms_pubsub_key_id

  message_retention_duration = "604800s"  # 7 días para replay

  message_storage_policy {
    allowed_persistence_regions = [var.region]
  }

  depends_on = [var.kms_pubsub_dependency]
}

# -----------------------------------------------------------------------------
# DLQ topics
# -----------------------------------------------------------------------------
resource "google_pubsub_topic" "dlq" {
  project = var.project_id
  name    = "${var.prefix}-dlq"

  kms_key_name               = var.kms_pubsub_key_id
  message_retention_duration = "604800s"

  depends_on = [var.kms_pubsub_dependency]
}

resource "google_pubsub_subscription" "dlq_inspect" {
  project                    = var.project_id
  name                       = "${var.prefix}-dlq-inspect"
  topic                      = google_pubsub_topic.dlq.name
  ack_deadline_seconds       = 600
  message_retention_duration = "604800s"
}

# -----------------------------------------------------------------------------
# Topic: data breach events (Art. 20 LFPDPPP)
# -----------------------------------------------------------------------------
resource "google_pubsub_topic" "breach_events" {
  project = var.project_id
  name    = "${var.prefix}-breach-events"

  kms_key_name               = var.kms_pubsub_key_id
  message_retention_duration = "2592000s"  # 30 días

  depends_on = [var.kms_pubsub_dependency]
}

resource "google_pubsub_subscription" "breach_response" {
  project              = var.project_id
  name                 = "${var.prefix}-breach-response-sub"
  topic                = google_pubsub_topic.breach_events.name
  ack_deadline_seconds = 60

  expiration_policy { ttl = "" }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
}
