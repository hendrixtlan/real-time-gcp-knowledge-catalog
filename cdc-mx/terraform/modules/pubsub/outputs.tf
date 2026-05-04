output "gcs_notifications_topic_id" {
  value = google_pubsub_topic.gcs_notifications.id
}

output "gcs_notifications_topic_name" {
  value = google_pubsub_topic.gcs_notifications.name
}

output "gcs_notifications_subscription" {
  value = google_pubsub_subscription.gcs_notifications_sub.name
}

output "cdc_events_topic_id" {
  value = google_pubsub_topic.cdc_events.id
}

output "cdc_events_topic_name" {
  value = google_pubsub_topic.cdc_events.name
}

output "dlq_topic_id" {
  value = google_pubsub_topic.dlq.id
}

output "dlq_topic_name" {
  value = google_pubsub_topic.dlq.name
}

output "breach_events_topic_id" {
  value = google_pubsub_topic.breach_events.id
}

output "breach_events_topic_name" {
  value = google_pubsub_topic.breach_events.name
}
