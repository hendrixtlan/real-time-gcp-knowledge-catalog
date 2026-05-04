variable "project_id" { type = string }
variable "region" { type = string }
variable "prefix" { type = string }

# Para Pub/Sub schema y metadata change feed
variable "cdc_events_topic_id" {
  type        = string
  description = "ID del topic CDC events (projects/X/topics/Y) para asociar schema"
  default     = ""
}

# Para DataScans
variable "bq_analytics_dataset" {
  type        = string
  default     = "analytics"
  description = "Dataset donde Datastream aterriza el CDC"
}

variable "datascan_tables" {
  type = list(object({
    table_id           = string
    primary_key_column = string
  }))
  default = [
    { table_id = "APP_SCHEMA_CUSTOMERS",   primary_key_column = "CUSTOMER_ID" },
    { table_id = "APP_SCHEMA_ORDERS",      primary_key_column = "ORDER_ID" },
    { table_id = "APP_SCHEMA_ORDER_ITEMS", primary_key_column = "ITEM_ID" },
  ]
  description = "Tablas BQ a las que aplicar DataScans (DQ + profile)"
}

variable "kms_pubsub_key_id" {
  type        = string
  default     = ""
  description = "CMEK del topic de metadata changes (opcional)"
}
