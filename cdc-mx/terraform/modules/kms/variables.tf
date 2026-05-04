variable "project_id" {
  type = string
}

variable "region" {
  type = string

  validation {
    condition     = var.region == "northamerica-south1"
    error_message = "Para LFPDPPP estricto, region debe ser northamerica-south1."
  }
}

variable "prefix" {
  type = string
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "protection_level" {
  type        = string
  default     = "SOFTWARE"
  description = "SOFTWARE o HSM. HSM cuesta más pero requerido en algunos casos regulados."

  validation {
    condition     = contains(["SOFTWARE", "HSM"], var.protection_level)
    error_message = "protection_level debe ser SOFTWARE o HSM."
  }
}
