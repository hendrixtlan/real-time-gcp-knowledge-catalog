variable "project_id" { type = string }
variable "region" { type = string }
variable "prefix" { type = string }

variable "image_uri" {
  type        = string
  description = "URI completa de la imagen Docker en Artifact Registry"
}

variable "vpc_connector_id" { type = string }
variable "kms_storage_key_id" { type = string }

variable "alloydb_writer_secret" { type = string }
variable "alloydb_password_secret" { type = string }

variable "bq_analytics_dataset" { type = string }
variable "bq_ops_dataset" { type = string }

variable "breach_events_topic" { type = string }

variable "dlp_inspect_template" { type = string }
variable "dlp_deidentify_template" { type = string }
