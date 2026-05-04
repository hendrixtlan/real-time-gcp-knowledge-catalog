output "notification_channel_id" {
  value = google_monitoring_notification_channel.email.id
}

output "dashboard_id" {
  value = google_monitoring_dashboard.main.id
}

output "alert_policies" {
  value = {
    datastream_lag    = google_monitoring_alert_policy.datastream_lag.id
    dataflow_lag      = google_monitoring_alert_policy.dataflow_lag.id
    alloydb_cpu       = google_monitoring_alert_policy.alloydb_cpu.id
    dlq_messages      = google_monitoring_alert_policy.dlq_messages.id
    arco_sla_critical = google_monitoring_alert_policy.arco_sla_critical.id
    data_breach       = google_monitoring_alert_policy.data_breach.id
  }
}
