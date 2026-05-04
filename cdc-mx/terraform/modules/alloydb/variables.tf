variable "project_id" { type = string }
variable "region" { type = string }
variable "prefix" { type = string }
variable "vpc_id" { type = string }
variable "kms_key_id" { type = string }
variable "initial_password" {
  type      = string
  sensitive = true
}

variable "primary_cpu_count" {
  type    = number
  default = 4
}

variable "read_pool_cpu_count" {
  type    = number
  default = 4
}

variable "read_pool_node_count" {
  type    = number
  default = 2
}

# Dependencias para que TF respete orden
variable "networking_dependency" {
  type        = any
  description = "Pasar el output alloydb_peering_dependency del módulo networking"
}

variable "kms_dependency" {
  type        = any
  description = "Pasar el output iam_bindings.alloydb del módulo kms"
}
