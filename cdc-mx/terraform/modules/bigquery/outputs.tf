output "analytics_dataset_id" {
  value = google_bigquery_dataset.analytics.dataset_id
}

output "ops_dataset_id" {
  value = google_bigquery_dataset.ops.dataset_id
}

output "cdc_lag_table_id" {
  value = google_bigquery_table.cdc_lag.table_id
}

output "arco_audit_table_id" {
  value = google_bigquery_table.arco_audit.table_id
}
