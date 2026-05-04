output "keyring_id" {
  value = google_kms_key_ring.main.id
}

output "key_bigquery_id" {
  value = google_kms_crypto_key.keys["bigquery"].id
}

output "key_alloydb_id" {
  value = google_kms_crypto_key.keys["alloydb"].id
}

output "key_storage_id" {
  value = google_kms_crypto_key.keys["storage"].id
}

output "key_pubsub_id" {
  value = google_kms_crypto_key.keys["pubsub"].id
}

# Dependencias para depends_on en otros módulos
output "iam_bindings" {
  value = {
    bigquery = google_kms_crypto_key_iam_member.bigquery.id
    alloydb  = google_kms_crypto_key_iam_member.alloydb.id
    storage  = google_kms_crypto_key_iam_member.storage.id
    pubsub   = google_kms_crypto_key_iam_member.pubsub.id
  }
}
