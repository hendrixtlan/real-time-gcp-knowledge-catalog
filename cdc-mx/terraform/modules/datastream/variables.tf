variable "project_id" { type = string }
variable "region" { type = string }
variable "prefix" { type = string }

# Oracle
variable "oracle_host" { type = string }
variable "oracle_port" {
  type    = number
  default = 1521
}
variable "oracle_service_name" { type = string }
variable "oracle_user" {
  type    = string
  default = "DATASTREAM_CDC"
}
variable "oracle_password_secret_id" { type = string }

# Networking
variable "private_connection_id" { type = string }

# KMS
variable "kms_storage_key_id" { type = string }
variable "kms_storage_dependency" { type = any }

# Pub/Sub para notificaciones de GCS
variable "gcs_notification_topic_id" { type = string }

# BigQuery
variable "bq_analytics_dataset" {
  type    = string
  default = "analytics"
}

# Tablas
variable "tables" {
  type = list(object({
    schema = string
    table  = string
  }))
  description = "Lista de tablas Oracle a replicar"
}
