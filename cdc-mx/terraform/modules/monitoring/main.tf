# =============================================================================
# Module: monitoring
# Alertas críticas y dashboard.
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

resource "google_monitoring_notification_channel" "email" {
  project      = var.project_id
  display_name = "${var.prefix}-email-ops"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
}

# -----------------------------------------------------------------------------
# Alerta: Datastream lag p99 > 30s
# -----------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "datastream_lag" {
  project      = var.project_id
  display_name = "${var.prefix} - Datastream lag p99 alto"
  combiner     = "OR"

  conditions {
    display_name = "Lag > 30s sostenido 5min"

    condition_threshold {
      filter          = "resource.type=\"datastream.googleapis.com/Stream\" AND metric.type=\"datastream.googleapis.com/stream/total_latency\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 30000

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_PERCENTILE_99"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
  alert_strategy {
    auto_close = "1800s"
  }
}

# -----------------------------------------------------------------------------
# Alerta: Dataflow system lag
# -----------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "dataflow_lag" {
  project      = var.project_id
  display_name = "${var.prefix} - Dataflow serving system lag"
  combiner     = "OR"

  conditions {
    display_name = "System lag > 60s"

    condition_threshold {
      filter          = "resource.type=\"dataflow_job\" AND metric.type=\"dataflow.googleapis.com/job/system_lag\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 60

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}

# -----------------------------------------------------------------------------
# Alerta: AlloyDB CPU
# -----------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "alloydb_cpu" {
  project      = var.project_id
  display_name = "${var.prefix} - AlloyDB CPU > 80%"
  combiner     = "OR"

  conditions {
    display_name = "CPU > 80% por 5 min"

    condition_threshold {
      filter          = "resource.type=\"alloydb.googleapis.com/Instance\" AND metric.type=\"alloydb.googleapis.com/instance/cpu/utilization\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}

# -----------------------------------------------------------------------------
# Alerta: DLQ con mensajes
# -----------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "dlq_messages" {
  project      = var.project_id
  display_name = "${var.prefix} - DLQ tiene mensajes"
  combiner     = "OR"

  conditions {
    display_name = "DLQ > 0"

    condition_threshold {
      filter          = "resource.type=\"pubsub_subscription\" AND metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\" AND resource.label.subscription_id=~\".*-dlq-.*\""
      duration        = "60s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}

# -----------------------------------------------------------------------------
# Alerta: ARCO SLA crítico
# -----------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "arco_sla_critical" {
  project      = var.project_id
  display_name = "${var.prefix} - ARCO SLA Art. 22 crítico"
  combiner     = "OR"

  conditions {
    display_name = "Solicitud ARCO a < 24h del SLA sin resolver"

    condition_matched_log {
      filter = "jsonPayload.event_type=\"ARCO_SLA_CRITICAL\""
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}

# -----------------------------------------------------------------------------
# Alerta: brecha detectada
# -----------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "data_breach" {
  project      = var.project_id
  display_name = "${var.prefix} - Vulneración de seguridad detectada (Art. 20)"
  combiner     = "OR"

  conditions {
    display_name = "Evento DATA_BREACH_DETECTED"

    condition_matched_log {
      filter = "jsonPayload.event_type=\"DATA_BREACH_DETECTED\""
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  documentation {
    content   = <<-EOT
      Vulneración de seguridad detectada. Activar playbook IR.
      Plazo Art. 20 LFPDPPP: notificar a titulares "en cuanto se confirme".
      Recomendado: 72h desde confirmación.
    EOT
    mime_type = "text/markdown"
  }
}

# -----------------------------------------------------------------------------
# Dashboard
# -----------------------------------------------------------------------------
resource "google_monitoring_dashboard" "main" {
  project = var.project_id

  dashboard_json = jsonencode({
    displayName = "${var.prefix} - CDC + LFPDPPP Overview"
    gridLayout = {
      columns = 2
      widgets = [
        {
          title = "Datastream lag p99 (ms)"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter = "resource.type=\"datastream.googleapis.com/Stream\" AND metric.type=\"datastream.googleapis.com/stream/total_latency\""
                  aggregation = {
                    alignmentPeriod    = "60s"
                    perSeriesAligner   = "ALIGN_PERCENTILE_99"
                    crossSeriesReducer = "REDUCE_MAX"
                  }
                }
              }
            }]
          }
        },
        {
          title = "Dataflow elements/sec"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter = "resource.type=\"dataflow_job\" AND metric.type=\"dataflow.googleapis.com/job/elements_produced_count\""
                  aggregation = {
                    alignmentPeriod  = "60s"
                    perSeriesAligner = "ALIGN_RATE"
                  }
                }
              }
            }]
          }
        },
        {
          title = "AlloyDB CPU"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter = "resource.type=\"alloydb.googleapis.com/Instance\" AND metric.type=\"alloydb.googleapis.com/instance/cpu/utilization\""
                  aggregation = {
                    alignmentPeriod  = "60s"
                    perSeriesAligner = "ALIGN_MEAN"
                  }
                }
              }
            }]
          }
        },
        {
          title = "AlloyDB connections"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter = "resource.type=\"alloydb.googleapis.com/Instance\" AND metric.type=\"alloydb.googleapis.com/instance/postgres/connections\""
                  aggregation = {
                    alignmentPeriod  = "60s"
                    perSeriesAligner = "ALIGN_MEAN"
                  }
                }
              }
            }]
          }
        }
      ]
    }
  })
}
