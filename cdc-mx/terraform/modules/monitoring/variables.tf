variable "project_id" { type = string }
variable "region" { type = string }
variable "prefix" { type = string }

variable "alert_email" {
  type        = string
  description = "Email para recibir alertas operacionales"
}
