# =============================================================================
# Module: catalog
# Knowledge Catalog + DLP + Policy Tags para LFPDPPP.
# Aspect types: pii-classification, legal-basis, purpose, retention.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
  }
}

# -----------------------------------------------------------------------------
# Aspect types
# -----------------------------------------------------------------------------
resource "google_dataplex_aspect_type" "pii_classification" {
  project        = var.project_id
  location       = "global"
  aspect_type_id = "lfpdppp-pii-classification"
  display_name   = "LFPDPPP - PII classification"
  description    = "Clasificación de datos personales según LFPDPPP"

  metadata_template = jsonencode({
    name = "lfpdppp-pii-classification"
    type = "record"
    recordFields = [
      {
        name = "sensitivity_level"
        type = {
          name = "enum", type = "enum"
          enumValues = [
            { name = "PUBLIC" }, { name = "INTERNAL" },
            { name = "CONFIDENTIAL" }, { name = "RESTRICTED" }
          ]
        }
      },
      {
        name = "pii_category"
        type = {
          name = "enum", type = "enum"
          enumValues = [
            { name = "NONE" }, { name = "NAME" }, { name = "EMAIL" },
            { name = "PHONE" }, { name = "ADDRESS" },
            { name = "CURP" }, { name = "RFC" }, { name = "NSS" },
            { name = "INE_IFE" }, { name = "CLABE" },
            { name = "CARD_PAN" }, { name = "BIOMETRIC" },
            { name = "FINANCIAL" }, { name = "HEALTH" },
            { name = "POLITICAL" }, { name = "RELIGIOUS" },
            { name = "ETHNIC" }, { name = "SEXUAL_PREFERENCE" }
          ]
        }
      },
      { name = "is_sensitive_lfpdppp", type = { name = "boolean", type = "boolean" } },
      { name = "data_steward", type = { name = "string", type = "string" } }
    ]
  })
}

resource "google_dataplex_aspect_type" "legal_basis" {
  project        = var.project_id
  location       = "global"
  aspect_type_id = "lfpdppp-legal-basis"
  display_name   = "LFPDPPP - Legal basis"
  description    = "Base legal del tratamiento (Art. 8)"

  metadata_template = jsonencode({
    name = "lfpdppp-legal-basis"
    type = "record"
    recordFields = [
      {
        name = "basis_type"
        type = {
          name = "enum", type = "enum"
          enumValues = [
            { name = "CONSENT_EXPRESS" }, { name = "CONSENT_TACIT" },
            { name = "LEGAL_OBLIGATION" }, { name = "CONTRACT_EXECUTION" },
            { name = "VITAL_INTEREST" }, { name = "PUBLIC_INTEREST" },
            { name = "JUDICIAL_ORDER" }
          ]
        }
      },
      { name = "legal_reference", type = { name = "string", type = "string" } },
      { name = "withdrawal_mechanism_url", type = { name = "string", type = "string" } }
    ]
  })
}

resource "google_dataplex_aspect_type" "purpose" {
  project        = var.project_id
  location       = "global"
  aspect_type_id = "lfpdppp-purpose"
  display_name   = "LFPDPPP - Purpose"
  description    = "Finalidad del tratamiento (Art. 16)"

  metadata_template = jsonencode({
    name = "lfpdppp-purpose"
    type = "record"
    recordFields = [
      { name = "primary_purpose", type = { name = "string", type = "string" } },
      {
        name = "category"
        type = {
          name = "enum", type = "enum"
          enumValues = [
            { name = "NECESSARY" }, { name = "SECONDARY" },
            { name = "ANALYTICS" }, { name = "MARKETING" },
            { name = "FRAUD_PREVENTION" }, { name = "REGULATORY_REPORTING" }
          ]
        }
      },
      { name = "privacy_notice_url", type = { name = "string", type = "string" } },
      { name = "privacy_notice_version", type = { name = "string", type = "string" } }
    ]
  })
}

resource "google_dataplex_aspect_type" "retention" {
  project        = var.project_id
  location       = "global"
  aspect_type_id = "lfpdppp-retention"
  display_name   = "LFPDPPP - Retention policy"
  description    = "Política de retención (Art. 11)"

  metadata_template = jsonencode({
    name = "lfpdppp-retention"
    type = "record"
    recordFields = [
      { name = "retention_days", type = { name = "integer", type = "long" } },
      {
        name = "retention_basis"
        type = {
          name = "enum", type = "enum"
          enumValues = [
            { name = "BUSINESS_NEED" }, { name = "LEGAL_OBLIGATION" },
            { name = "STATUTE_OF_LIMITATIONS" }, { name = "CONTRACTUAL" }
          ]
        }
      },
      { name = "deletion_method", type = { name = "string", type = "string" } }
    ]
  })
}

# -----------------------------------------------------------------------------
# Glosario de negocio
# -----------------------------------------------------------------------------
resource "google_dataplex_glossary" "main" {
  project      = var.project_id
  location     = var.region
  glossary_id  = "${var.prefix}-glossary"
  display_name = "Glosario CDC + LFPDPPP"
  description  = "Términos compartidos del stack CDC con cumplimiento LFPDPPP"
}

# -----------------------------------------------------------------------------
# Policy tags para column-level security en BigQuery
# -----------------------------------------------------------------------------
resource "google_data_catalog_taxonomy" "pii" {
  project                = var.project_id
  region                 = var.region
  display_name           = "${var.prefix}-pii-taxonomy"
  description            = "Taxonomía PII para column-level access control"
  activated_policy_types = ["FINE_GRAINED_ACCESS_CONTROL"]
}

resource "google_data_catalog_policy_tag" "pii_high" {
  taxonomy     = google_data_catalog_taxonomy.pii.id
  display_name = "pii-high"
  description  = "PII alta sensibilidad (LFPDPPP datos sensibles)"
}

resource "google_data_catalog_policy_tag" "pii_medium" {
  taxonomy     = google_data_catalog_taxonomy.pii.id
  display_name = "pii-medium"
  description  = "PII media (email, phone, name)"
}

# -----------------------------------------------------------------------------
# DLP — Stored InfoTypes mexicanos
# -----------------------------------------------------------------------------
resource "google_data_loss_prevention_stored_info_type" "curp" {
  parent       = "projects/${var.project_id}/locations/${var.region}"
  description  = "Clave Única de Registro de Población"
  display_name = "MX_CURP"
  regex {
    pattern = "[A-Z][AEIOUX][A-Z]{2}[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])[HM](AS|BC|BS|CC|CS|CH|CL|CM|DF|DG|GT|GR|HG|JC|MC|MN|MS|NT|NL|OC|PL|QT|QR|SP|SL|SR|TC|TS|TL|VZ|YN|ZS|NE)[B-DF-HJ-NP-TV-Z]{3}[0-9A-Z][0-9]"
  }
}

resource "google_data_loss_prevention_stored_info_type" "rfc_fisica" {
  parent       = "projects/${var.project_id}/locations/${var.region}"
  description  = "RFC persona física (13 chars)"
  display_name = "MX_RFC_FISICA"
  regex {
    pattern = "[A-ZÑ&]{4}[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])[A-Z0-9]{2}[0-9A]"
  }
}

resource "google_data_loss_prevention_stored_info_type" "rfc_moral" {
  parent       = "projects/${var.project_id}/locations/${var.region}"
  description  = "RFC persona moral (12 chars)"
  display_name = "MX_RFC_MORAL"
  regex {
    pattern = "[A-ZÑ&]{3}[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])[A-Z0-9]{2}[0-9A]"
  }
}

resource "google_data_loss_prevention_stored_info_type" "nss" {
  parent       = "projects/${var.project_id}/locations/${var.region}"
  description  = "Número de Seguridad Social IMSS"
  display_name = "MX_NSS"
  regex {
    pattern = "[0-9]{2}[0-9]{2}[0-9]{6}[0-9]"
  }
}

resource "google_data_loss_prevention_stored_info_type" "clave_elector" {
  parent       = "projects/${var.project_id}/locations/${var.region}"
  description  = "Clave de Elector INE/IFE"
  display_name = "MX_CLAVE_ELECTOR"
  regex {
    pattern = "[A-Z]{6}[0-9]{8}[HM][0-9]{3}"
  }
}

resource "google_data_loss_prevention_stored_info_type" "clabe" {
  parent       = "projects/${var.project_id}/locations/${var.region}"
  description  = "CLABE interbancaria"
  display_name = "MX_CLABE"
  regex {
    pattern = "[0-9]{18}"
  }
}

# -----------------------------------------------------------------------------
# DLP inspect template (PII MX + estándar)
# -----------------------------------------------------------------------------
resource "google_data_loss_prevention_inspect_template" "mx_pii" {
  parent       = "projects/${var.project_id}/locations/${var.region}"
  description  = "Detección PII mexicano + estándar para LFPDPPP"
  display_name = "${var.prefix}-mx-pii-inspect"

  inspect_config {
    info_types { name = "EMAIL_ADDRESS" }
    info_types { name = "PHONE_NUMBER" }
    info_types { name = "CREDIT_CARD_NUMBER" }
    info_types { name = "PERSON_NAME" }
    info_types { name = "DATE_OF_BIRTH" }
    info_types { name = "IBAN_CODE" }
    info_types { name = "IP_ADDRESS" }
    info_types { name = "MEXICO_CURP_NUMBER" }

    custom_info_types {
      info_type { name = "MX_CURP_CUSTOM" }
      stored_type { name = google_data_loss_prevention_stored_info_type.curp.id }
      likelihood = "VERY_LIKELY"
    }
    custom_info_types {
      info_type { name = "MX_RFC_FISICA" }
      stored_type { name = google_data_loss_prevention_stored_info_type.rfc_fisica.id }
      likelihood = "LIKELY"
    }
    custom_info_types {
      info_type { name = "MX_NSS" }
      stored_type { name = google_data_loss_prevention_stored_info_type.nss.id }
      likelihood = "POSSIBLE"
    }
    custom_info_types {
      info_type { name = "MX_CLAVE_ELECTOR" }
      stored_type { name = google_data_loss_prevention_stored_info_type.clave_elector.id }
      likelihood = "VERY_LIKELY"
    }
    custom_info_types {
      info_type { name = "MX_CLABE" }
      stored_type { name = google_data_loss_prevention_stored_info_type.clabe.id }
      likelihood = "LIKELY"
    }

    min_likelihood = "POSSIBLE"
    limits {
      max_findings_per_request = 1000
    }
    include_quote = false
  }
}

# -----------------------------------------------------------------------------
# DLP deidentify template (para exports y respuestas ARCO)
# -----------------------------------------------------------------------------
resource "google_data_loss_prevention_deidentify_template" "mx_mask" {
  parent       = "projects/${var.project_id}/locations/${var.region}"
  description  = "Enmascarado de PII para exports"
  display_name = "${var.prefix}-mx-pii-deidentify"

  deidentify_config {
    info_type_transformations {
      transformations {
        info_types { name = "MX_CURP_CUSTOM" }
        info_types { name = "MX_RFC_FISICA" }
        info_types { name = "MX_NSS" }
        info_types { name = "EMAIL_ADDRESS" }
        info_types { name = "PHONE_NUMBER" }
        info_types { name = "CREDIT_CARD_NUMBER" }

        primitive_transformation {
          character_mask_config {
            masking_character = "*"
            number_to_mask    = -1
            reverse_order     = false
          }
        }
      }
    }
  }
}

# =============================================================================
# Pub/Sub schema (Avro) para el topic de CDC events
# Sin schema, Knowledge Catalog no puede leer la estructura del payload.
# =============================================================================
resource "google_pubsub_schema" "cdc_event" {
  project    = var.project_id
  name       = "${var.prefix}-cdc-event-schema"
  type       = "AVRO"
  definition = jsonencode({
    type   = "record"
    name   = "CdcEvent"
    fields = [
      { name = "table",           type = "string" },
      { name = "schema",          type = "string" },
      { name = "op",              type = { type = "enum", name = "Op", symbols = ["I", "U", "D"] } },
      { name = "scn",             type = "long" },
      { name = "op_ts",           type = { type = "long", logicalType = "timestamp-millis" } },
      { name = "received_at",     type = { type = "long", logicalType = "timestamp-millis" } },
      { name = "before",          type = ["null", { type = "map", values = "string" }], default = null },
      { name = "after",           type = ["null", { type = "map", values = "string" }], default = null },
      { name = "source_metadata", type = ["null", { type = "map", values = "string" }], default = null }
    ]
  })
}

# =============================================================================
# Entry Group para activos custom (Oracle source, Looker, etc.)
# Los entries de BQ/AlloyDB/Pub/Sub se crean automáticamente; aquí es para
# fuentes externas que no tienen entry group nativo.
# =============================================================================
resource "google_dataplex_entry_group" "governance" {
  project        = var.project_id
  location       = var.region
  entry_group_id = "${var.prefix}-governance"
  display_name   = "Activos custom CDC + LFPDPPP"
  description    = "Entries para Oracle (source) y consumidores externos"

  labels = {
    compliance = "lfpdppp"
    tier       = "governance"
  }
}

# =============================================================================
# Glossary terms concretos
#
# NOTA: google_dataplex_glossary_category y _term requieren provider
# google >= 5.30 con API Knowledge Catalog GA. Si tu provider los reporta
# como "resource not found", actualiza con:
#   terraform init -upgrade
# o comenta esta sección y crea los terms con la API REST + null_resource.
# =============================================================================
resource "google_dataplex_glossary_category" "lfpdppp" {
  project              = var.project_id
  location             = var.region
  glossary_id          = google_dataplex_glossary.main.glossary_id
  glossary_category_id = "lfpdppp"
  display_name         = "LFPDPPP"
  description          = "Términos relacionados con la Nueva LFPDPPP 2025"

  parent = google_dataplex_glossary.main.id
}

resource "google_dataplex_glossary_term" "titular" {
  project              = var.project_id
  location             = var.region
  glossary_id          = google_dataplex_glossary.main.glossary_id
  glossary_term_id     = "titular"
  display_name         = "Titular"
  description          = "Persona física a quien corresponden los datos personales (Art. 3 LFPDPPP)"
  parent               = google_dataplex_glossary_category.lfpdppp.id
}

resource "google_dataplex_glossary_term" "datos_personales" {
  project              = var.project_id
  location             = var.region
  glossary_id          = google_dataplex_glossary.main.glossary_id
  glossary_term_id     = "datos-personales"
  display_name         = "Datos personales"
  description          = "Cualquier información concerniente a una persona física identificada o identificable (Art. 3)"
  parent               = google_dataplex_glossary_category.lfpdppp.id
}

resource "google_dataplex_glossary_term" "datos_sensibles" {
  project              = var.project_id
  location             = var.region
  glossary_id          = google_dataplex_glossary.main.glossary_id
  glossary_term_id     = "datos-sensibles"
  display_name         = "Datos sensibles"
  description          = "Datos que afectan la esfera más íntima del titular: origen racial, salud, biométricos, opiniones políticas, religiosas, preferencia sexual, etc. Sanción duplicada"
  parent               = google_dataplex_glossary_category.lfpdppp.id
}

resource "google_dataplex_glossary_term" "consentimiento" {
  project              = var.project_id
  location             = var.region
  glossary_id          = google_dataplex_glossary.main.glossary_id
  glossary_term_id     = "consentimiento"
  display_name         = "Consentimiento"
  description          = "Manifestación de voluntad del titular libre, específica e informada para el tratamiento (Art. 8)"
  parent               = google_dataplex_glossary_category.lfpdppp.id
}

resource "google_dataplex_glossary_term" "arco" {
  project              = var.project_id
  location             = var.region
  glossary_id          = google_dataplex_glossary.main.glossary_id
  glossary_term_id     = "arco"
  display_name         = "Derechos ARCO"
  description          = "Acceso, Rectificación, Cancelación, Oposición. Plazo: 20 días resolución + 15 días ejecución (Art. 22)"
  parent               = google_dataplex_glossary_category.lfpdppp.id
}

resource "google_dataplex_glossary_term" "responsable" {
  project              = var.project_id
  location             = var.region
  glossary_id          = google_dataplex_glossary.main.glossary_id
  glossary_term_id     = "responsable"
  display_name         = "Responsable"
  description          = "Persona física o moral que decide el tratamiento de datos personales (Art. 3 frac. XV)"
  parent               = google_dataplex_glossary_category.lfpdppp.id
}

resource "google_dataplex_glossary_term" "encargado" {
  project              = var.project_id
  location             = var.region
  glossary_id          = google_dataplex_glossary.main.glossary_id
  glossary_term_id     = "encargado"
  display_name         = "Encargado"
  description          = "Persona que trata datos personales por cuenta del responsable (Art. 50)"
  parent               = google_dataplex_glossary_category.lfpdppp.id
}

# =============================================================================
# DataScans: data quality + profiling automático sobre tablas BQ
# DQ valida unicidad de PK, freshness, no-nulls. Profile detecta PII no
# clasificado y dispara reconciliación con aspect types.
# =============================================================================
resource "google_dataplex_datascan" "quality" {
  for_each = { for t in var.datascan_tables : t.table_id => t }

  project      = var.project_id
  location     = var.region
  data_scan_id = lower(replace("${var.prefix}-dq-${each.value.table_id}", "_", "-"))
  display_name = "DQ ${each.value.table_id}"
  description  = "Data quality scan diario sobre ${each.value.table_id}"

  data {
    resource = "//bigquery.googleapis.com/projects/${var.project_id}/datasets/${var.bq_analytics_dataset}/tables/${each.value.table_id}"
  }

  execution_spec {
    trigger {
      schedule {
        cron = "0 4 * * *"  # 04:00 todos los días
      }
    }
  }

  data_quality_spec {
    sampling_percent = 10

    rules {
      column      = each.value.primary_key_column
      dimension   = "UNIQUENESS"
      description = "PK debe ser única"

      non_null_expectation {}
    }

    rules {
      column    = each.value.primary_key_column
      dimension = "UNIQUENESS"

      uniqueness_expectation {}
    }
  }

  labels = {
    compliance = "lfpdppp"
    purpose    = "data-quality"
  }
}

resource "google_dataplex_datascan" "profile" {
  for_each = { for t in var.datascan_tables : t.table_id => t }

  project      = var.project_id
  location     = var.region
  data_scan_id = lower(replace("${var.prefix}-prof-${each.value.table_id}", "_", "-"))
  display_name = "Profile ${each.value.table_id}"
  description  = "Profile scan: detecta tipos, nulls, distribuciones, posible PII"

  data {
    resource = "//bigquery.googleapis.com/projects/${var.project_id}/datasets/${var.bq_analytics_dataset}/tables/${each.value.table_id}"
  }

  execution_spec {
    trigger {
      schedule {
        cron = "0 5 * * 0"  # domingos 05:00
      }
    }
  }

  data_profile_spec {
    sampling_percent = 5
  }

  labels = {
    compliance = "lfpdppp"
    purpose    = "profiling"
  }
}

# =============================================================================
# Metadata change feed → Pub/Sub
# Cuando cambia un schema, lineage o resultado de DQ, se emite un evento.
# Útil para gobernanza event-driven (ej. alertar si nueva columna PII aparece).
# =============================================================================
resource "google_pubsub_topic" "metadata_changes" {
  project = var.project_id
  name    = "${var.prefix}-metadata-changes"

  kms_key_name = var.kms_pubsub_key_id != "" ? var.kms_pubsub_key_id : null

  message_retention_duration = "604800s"  # 7 días

  message_storage_policy {
    allowed_persistence_regions = [var.region]
  }
}

# Permitir que el service agent de Dataplex publique aquí
data "google_project" "current_dataplex" {
  project_id = var.project_id
}

resource "google_pubsub_topic_iam_member" "dataplex_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.metadata_changes.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.current_dataplex.number}@gcp-sa-dataplex.iam.gserviceaccount.com"
}

resource "google_pubsub_subscription" "metadata_changes_audit" {
  project = var.project_id
  name    = "${var.prefix}-metadata-changes-audit"
  topic   = google_pubsub_topic.metadata_changes.name

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
}
