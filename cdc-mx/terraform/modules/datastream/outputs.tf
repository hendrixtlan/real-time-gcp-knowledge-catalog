output "landing_bucket_name" {
  value = google_storage_bucket.landing.name
}

output "landing_bucket_id" {
  value = google_storage_bucket.landing.id
}

output "stream_to_bq_id" {
  value = google_datastream_stream.oracle_to_bq.id
}

output "stream_to_gcs_id" {
  value = google_datastream_stream.oracle_to_gcs.id
}
