output "pii_taxonomy_id" {
  value = google_data_catalog_taxonomy.pii.id
}

output "policy_tag_pii_high" {
  value = google_data_catalog_policy_tag.pii_high.id
}

output "policy_tag_pii_medium" {
  value = google_data_catalog_policy_tag.pii_medium.id
}

output "dlp_inspect_template_id" {
  value = google_data_loss_prevention_inspect_template.mx_pii.id
}

output "dlp_deidentify_template_id" {
  value = google_data_loss_prevention_deidentify_template.mx_mask.id
}

output "glossary_id" {
  value = google_dataplex_glossary.main.id
}

output "aspect_type_pii_id" {
  value = google_dataplex_aspect_type.pii_classification.id
}

output "aspect_type_legal_basis_id" {
  value = google_dataplex_aspect_type.legal_basis.id
}

output "aspect_type_purpose_id" {
  value = google_dataplex_aspect_type.purpose.id
}

output "aspect_type_retention_id" {
  value = google_dataplex_aspect_type.retention.id
}

# Pub/Sub schema
output "cdc_event_schema_id" {
  value = google_pubsub_schema.cdc_event.id
}

# Entry group
output "entry_group_id" {
  value = google_dataplex_entry_group.governance.id
}

output "entry_group_name" {
  value = google_dataplex_entry_group.governance.name
}

# DataScans
output "datascan_quality_ids" {
  value = { for k, v in google_dataplex_datascan.quality : k => v.id }
}

output "datascan_profile_ids" {
  value = { for k, v in google_dataplex_datascan.profile : k => v.id }
}

# Metadata change feed
output "metadata_changes_topic_id" {
  value = google_pubsub_topic.metadata_changes.id
}

output "metadata_changes_topic_name" {
  value = google_pubsub_topic.metadata_changes.name
}

output "metadata_changes_subscription" {
  value = google_pubsub_subscription.metadata_changes_audit.name
}

# Glossary terms (referenciables desde post-deploy script)
output "glossary_term_ids" {
  value = {
    titular           = google_dataplex_glossary_term.titular.id
    datos_personales  = google_dataplex_glossary_term.datos_personales.id
    datos_sensibles   = google_dataplex_glossary_term.datos_sensibles.id
    consentimiento    = google_dataplex_glossary_term.consentimiento.id
    arco              = google_dataplex_glossary_term.arco.id
    responsable       = google_dataplex_glossary_term.responsable.id
    encargado         = google_dataplex_glossary_term.encargado.id
  }
}
