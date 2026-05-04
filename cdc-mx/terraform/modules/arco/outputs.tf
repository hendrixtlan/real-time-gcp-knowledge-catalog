output "service_url" {
  value = google_cloud_run_v2_service.arco.uri
}

output "service_account_email" {
  value = google_service_account.arco.email
}

output "exports_bucket" {
  value = google_storage_bucket.arco_exports.name
}
