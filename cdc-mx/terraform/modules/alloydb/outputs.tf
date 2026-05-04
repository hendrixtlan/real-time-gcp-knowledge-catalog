output "cluster_id" {
  value = google_alloydb_cluster.main.cluster_id
}

output "cluster_name" {
  value = google_alloydb_cluster.main.name
}

output "primary_ip" {
  value = google_alloydb_instance.primary.ip_address
}

output "read_pool_ip" {
  value = google_alloydb_instance.read_pool.ip_address
}

output "primary_instance_id" {
  value = google_alloydb_instance.primary.instance_id
}

output "read_pool_instance_id" {
  value = google_alloydb_instance.read_pool.instance_id
}
