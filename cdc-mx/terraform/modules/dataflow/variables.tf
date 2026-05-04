variable "project_id" { type = string }
variable "region" { type = string }
variable "prefix" { type = string }
variable "environment" { type = string }
variable "vpc_name" { type = string }
variable "subnet_name" { type = string }

variable "kms_storage_key_id" { type = string }

variable "flex_template_gcs_path" {
  type        = string
  description = "Path GCS al spec del flex template generado por build_and_deploy.sh"
}

variable "gcs_notifications_subscription" { type = string }
variable "cdc_events_topic" { type = string }
variable "dlq_topic" { type = string }

variable "alloydb_writer_secret" { type = string }
variable "alloydb_password_secret" { type = string }

variable "machine_type" {
  type    = string
  default = "n1-standard-4"
}

variable "num_workers" {
  type    = number
  default = 2
}

variable "max_workers" {
  type    = number
  default = 10
}
