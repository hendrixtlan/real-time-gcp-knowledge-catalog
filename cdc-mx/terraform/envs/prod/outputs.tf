# =============================================================================
# Outputs útiles post-deploy
# =============================================================================

output "alloydb_primary_ip" {
  description = "IP privada del primario AlloyDB (solo accesible vía VPC)"
  value       = module.alloydb.primary_ip
}

output "alloydb_read_pool_ip" {
  description = "IP privada del read pool AlloyDB"
  value       = module.alloydb.read_pool_ip
}

output "alloydb_writer_secret_setup_cmd" {
  description = "Comando para poblar el secret de connection string post-deploy"
  value       = "gcloud secrets versions add ${var.prefix}-alloydb-writer-conn --data-file=- <<< 'host=${module.alloydb.primary_ip} port=5432 dbname=cdc_mx user=cdc_writer'"
  sensitive   = true
}

output "datastream_bq_stream_id" {
  value       = module.datastream.bq_stream_id
  description = "ID del stream Datastream→BigQuery"
}

output "datastream_gcs_stream_id" {
  value       = module.datastream.gcs_stream_id
  description = "ID del stream Datastream→GCS (sirve como source para AlloyDB)"
}

output "gcs_landing_bucket" {
  value       = module.datastream.gcs_landing_bucket
  description = "Bucket de landing donde Datastream escribe Avro"
}

output "bigquery_analytics_dataset" {
  value       = module.bigquery.analytics_dataset_id
  description = "Dataset de BigQuery con tablas CDC replicadas"
}

output "bigquery_ops_dataset" {
  value       = module.bigquery.ops_dataset_id
  description = "Dataset de BigQuery con tablas operacionales (auditoría, ARCO)"
}

output "arco_service_url" {
  value       = module.arco.service_url
  description = "URL del servicio ARCO (Cloud Run)"
}

output "audit_log_bucket" {
  value       = module.audit.log_bucket_name
  description = "Bucket donde se archivan los Data Access logs"
}

output "kms_key_ring" {
  value       = module.kms.key_ring_id
  description = "ID del key ring KMS"
}

output "artifact_registry_repo" {
  value       = google_artifact_registry_repository.main.id
  description = "Repo de Artifact Registry para imágenes Docker"
}

output "vpc_id" {
  value       = module.networking.vpc_id
  description = "ID de la VPC"
}

output "compliance_summary" {
  description = "Resumen de controles LFPDPPP activos"
  value = {
    region                  = var.region
    cmek_protection_level   = var.kms_protection_level
    cmek_separate_keys      = "alloydb, bigquery, pubsub, storage"
    audit_logs_retention    = "7 años (CFF Art. 67)"
    arco_sla_days           = 20
    breach_notification     = "automatizada vía Pub/Sub topic"
    deletion_with_blocking  = "soportada (LFPDPPP Art. 27)"
    dlp_mexican_infotypes   = "MX_CURP, MX_RFC, MX_NSS, MX_CLAVE_ELECTOR, MX_CLABE"
  }
}
