variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type        = string
  description = "GCP region (debe ser northamerica-south1 para LFPDPPP)"

  validation {
    condition     = var.region == "northamerica-south1"
    error_message = "Para cumplimiento LFPDPPP estricto, region debe ser northamerica-south1."
  }
}

variable "prefix" {
  type        = string
  description = "Prefix para nombres de recursos"
}
