output "vpc_id" {
  value = google_compute_network.vpc.id
}

output "vpc_name" {
  value = google_compute_network.vpc.name
}

output "vpc_self_link" {
  value = google_compute_network.vpc.self_link
}

output "subnet_primary_id" {
  value = google_compute_subnetwork.primary.id
}

output "subnet_primary_name" {
  value = google_compute_subnetwork.primary.name
}

output "subnet_dataflow_id" {
  value = google_compute_subnetwork.dataflow.id
}

output "subnet_dataflow_name" {
  value = google_compute_subnetwork.dataflow.name
}

output "datastream_private_connection_id" {
  value = google_datastream_private_connection.oracle.id
}

output "vpc_connector_id" {
  value = google_vpc_access_connector.main.id
}

output "alloydb_peering_dependency" {
  value       = google_service_networking_connection.alloydb_peering.id
  description = "Pasar como depends_on a módulo AlloyDB"
}
