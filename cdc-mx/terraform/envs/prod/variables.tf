variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type        = string
  default     = "northamerica-south1"
  description = "Región GCP. Para LFPDPPP estricto debe ser northamerica-south1."

  validation {
    condition     = var.region == "northamerica-south1"
    error_message = "Para cumplimiento LFPDPPP estricto, region debe ser northamerica-south1."
  }
}

variable "prefix" {
  type        = string
  default     = "cdc-mx"
  description = "Prefix para todos los recursos"
}

variable "alert_email" {
  type        = string
  description = "Email para alertas de monitoring"
}

# -----------------------------------------------------------------------------
# Oracle source
# -----------------------------------------------------------------------------
variable "oracle_host" {
  type        = string
  description = "IP o hostname Oracle alcanzable desde GCP via Cloud Interconnect/VPN"
}

variable "oracle_port" {
  type    = number
  default = 1521
}

variable "oracle_service_name" {
  type = string
}

variable "oracle_user" {
  type    = string
  default = "DATASTREAM_CDC"
}

variable "oracle_password" {
  type      = string
  sensitive = true
}

# -----------------------------------------------------------------------------
# Tablas a replicar
# -----------------------------------------------------------------------------
variable "cdc_tables" {
  type = list(object({
    schema = string
    table  = string
  }))
  description = "Lista de tablas Oracle a replicar (schema y nombre en MAYÚSCULAS)"

  default = [
    { schema = "APP_SCHEMA", table = "CUSTOMERS" },
    { schema = "APP_SCHEMA", table = "ORDERS" },
    { schema = "APP_SCHEMA", table = "ORDER_ITEMS" },
  ]
}

# -----------------------------------------------------------------------------
# AlloyDB
# -----------------------------------------------------------------------------
variable "alloydb_initial_password" {
  type      = string
  sensitive = true
}

variable "alloydb_primary_cpu_count" {
  type    = number
  default = 4
}

variable "alloydb_read_pool_cpu_count" {
  type    = number
  default = 4
}

variable "alloydb_read_pool_node_count" {
  type    = number
  default = 2
}

# -----------------------------------------------------------------------------
# KMS
# -----------------------------------------------------------------------------
variable "kms_protection_level" {
  type    = string
  default = "SOFTWARE"
}

# -----------------------------------------------------------------------------
# Dataflow
# -----------------------------------------------------------------------------
variable "dataflow_flex_template_gcs_path" {
  type        = string
  description = "Path al spec del template, generado por dataflow/serving/build_and_deploy.sh"
}

variable "dataflow_machine_type" {
  type    = string
  default = "n1-standard-4"
}

variable "dataflow_num_workers" {
  type    = number
  default = 2
}

variable "dataflow_max_workers" {
  type    = number
  default = 10
}

# -----------------------------------------------------------------------------
# Cloud Run images
# -----------------------------------------------------------------------------
variable "arco_image_uri" {
  type        = string
  description = "URI de la imagen ARCO en Artifact Registry"
}
