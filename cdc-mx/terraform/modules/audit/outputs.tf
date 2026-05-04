output "audit_archive_bucket" {
  value = google_storage_bucket.audit_archive.name
}

output "log_sink_name" {
  value = google_logging_project_sink.audit_archive.name
}

output "lag_metric_name" {
  value = google_logging_metric.cdc_e2e_lag.name
}
