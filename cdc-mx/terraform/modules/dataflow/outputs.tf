output "service_account_email" {
  value = google_service_account.dataflow.email
}

output "job_id" {
  value = google_dataflow_flex_template_job.serving.job_id
}

output "temp_bucket" {
  value = google_storage_bucket.temp.name
}
