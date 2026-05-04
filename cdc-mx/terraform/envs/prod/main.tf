# =============================================================================
# Environment: prod
# Composición de todos los módulos del stack CDC + LFPDPPP.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.30"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# -----------------------------------------------------------------------------
# Habilitar APIs necesarias
# -----------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",
    "vpcaccess.googleapis.com",
    "cloudkms.googleapis.com",
    "datastream.googleapis.com",
    "pubsub.googleapis.com",
    "alloydb.googleapis.com",
    "bigquery.googleapis.com",
    "dataflow.googleapis.com",
    "run.googleapis.com",
    "cloudscheduler.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "dataplex.googleapis.com",
    "datacatalog.googleapis.com",
    "dlp.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
  ])

  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

# -----------------------------------------------------------------------------
# Secrets Manager — passwords
# -----------------------------------------------------------------------------
resource "google_secret_manager_secret" "oracle_password" {
  project   = var.project_id
  secret_id = "${var.prefix}-oracle-password"

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "oracle_password" {
  secret      = google_secret_manager_secret.oracle_password.id
  secret_data = var.oracle_password
}

resource "google_secret_manager_secret" "alloydb_password" {
  project   = var.project_id
  secret_id = "${var.prefix}-alloydb-password"

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "alloydb_password" {
  secret      = google_secret_manager_secret.alloydb_password.id
  secret_data = var.alloydb_initial_password
}

# Connection string para AlloyDB (lo arma el operador después de crear el cluster)
# Por ahora secret vacío que se actualiza post-deploy
resource "google_secret_manager_secret" "alloydb_writer_conn" {
  project   = var.project_id
  secret_id = "${var.prefix}-alloydb-writer-conn"

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Artifact Registry para imágenes Docker
# -----------------------------------------------------------------------------
resource "google_artifact_registry_repository" "main" {
  project       = var.project_id
  location      = var.region
  repository_id = var.prefix
  description   = "Imágenes para servicios CDC"
  format        = "DOCKER"

  depends_on = [google_project_service.apis]
}

# =============================================================================
# Módulos del stack
# =============================================================================

module "networking" {
  source     = "../../modules/networking"
  project_id = var.project_id
  region     = var.region
  prefix     = var.prefix

  depends_on = [google_project_service.apis]
}

module "kms" {
  source           = "../../modules/kms"
  project_id       = var.project_id
  region           = var.region
  prefix           = var.prefix
  environment      = "prod"
  protection_level = var.kms_protection_level

  depends_on = [google_project_service.apis]
}

module "audit" {
  source             = "../../modules/audit"
  project_id         = var.project_id
  region             = var.region
  prefix             = var.prefix
  kms_storage_key_id = module.kms.key_storage_id

  depends_on = [module.kms]
}

module "catalog" {
  source                = "../../modules/catalog"
  project_id            = var.project_id
  region                = var.region
  prefix                = var.prefix
  cdc_events_topic_id   = module.pubsub.cdc_events_topic_id
  bq_analytics_dataset  = module.bigquery.analytics_dataset_id
  kms_pubsub_key_id     = module.kms.key_pubsub_id

  depends_on = [
    google_project_service.apis,
    module.bigquery,
    module.pubsub,
  ]
}

module "pubsub" {
  source                = "../../modules/pubsub"
  project_id            = var.project_id
  region                = var.region
  prefix                = var.prefix
  kms_pubsub_key_id     = module.kms.key_pubsub_id
  kms_pubsub_dependency = module.kms.iam_bindings.pubsub
}

module "bigquery" {
  source              = "../../modules/bigquery"
  project_id          = var.project_id
  region              = var.region
  prefix              = var.prefix
  kms_bigquery_key_id = module.kms.key_bigquery_id
  kms_dependency      = module.kms.iam_bindings.bigquery
}

module "alloydb" {
  source                = "../../modules/alloydb"
  project_id            = var.project_id
  region                = var.region
  prefix                = var.prefix
  vpc_id                = module.networking.vpc_id
  kms_key_id            = module.kms.key_alloydb_id
  initial_password      = var.alloydb_initial_password
  primary_cpu_count     = var.alloydb_primary_cpu_count
  read_pool_cpu_count   = var.alloydb_read_pool_cpu_count
  read_pool_node_count  = var.alloydb_read_pool_node_count
  networking_dependency = module.networking.alloydb_peering_dependency
  kms_dependency        = module.kms.iam_bindings.alloydb
}

module "datastream" {
  source                    = "../../modules/datastream"
  project_id                = var.project_id
  region                    = var.region
  prefix                    = var.prefix
  oracle_host               = var.oracle_host
  oracle_port               = var.oracle_port
  oracle_service_name       = var.oracle_service_name
  oracle_user               = var.oracle_user
  oracle_password_secret_id = google_secret_manager_secret.oracle_password.secret_id
  private_connection_id     = module.networking.datastream_private_connection_id
  kms_storage_key_id        = module.kms.key_storage_id
  kms_storage_dependency    = module.kms.iam_bindings.storage
  gcs_notification_topic_id = module.pubsub.gcs_notifications_topic_id
  bq_analytics_dataset      = module.bigquery.analytics_dataset_id
  tables                    = var.cdc_tables

  depends_on = [
    google_secret_manager_secret_version.oracle_password,
    module.bigquery,
  ]
}

module "dataflow" {
  source                         = "../../modules/dataflow"
  project_id                     = var.project_id
  region                         = var.region
  prefix                         = var.prefix
  environment                    = "prod"
  vpc_name                       = module.networking.vpc_name
  subnet_name                    = module.networking.subnet_dataflow_name
  kms_storage_key_id             = module.kms.key_storage_id
  flex_template_gcs_path         = var.dataflow_flex_template_gcs_path
  gcs_notifications_subscription = module.pubsub.gcs_notifications_subscription
  cdc_events_topic               = module.pubsub.cdc_events_topic_name
  dlq_topic                      = module.pubsub.dlq_topic_name
  alloydb_writer_secret          = google_secret_manager_secret.alloydb_writer_conn.secret_id
  alloydb_password_secret        = google_secret_manager_secret.alloydb_password.secret_id
  machine_type                   = var.dataflow_machine_type
  num_workers                    = var.dataflow_num_workers
  max_workers                    = var.dataflow_max_workers
}

module "arco" {
  source                  = "../../modules/arco"
  project_id              = var.project_id
  region                  = var.region
  prefix                  = var.prefix
  image_uri               = var.arco_image_uri
  vpc_connector_id        = module.networking.vpc_connector_id
  kms_storage_key_id      = module.kms.key_storage_id
  alloydb_writer_secret   = google_secret_manager_secret.alloydb_writer_conn.secret_id
  alloydb_password_secret = google_secret_manager_secret.alloydb_password.secret_id
  bq_analytics_dataset    = module.bigquery.analytics_dataset_id
  bq_ops_dataset          = module.bigquery.ops_dataset_id
  breach_events_topic     = module.pubsub.breach_events_topic_name
  dlp_inspect_template    = module.catalog.dlp_inspect_template_id
  dlp_deidentify_template = module.catalog.dlp_deidentify_template_id
}

module "monitoring" {
  source      = "../../modules/monitoring"
  project_id  = var.project_id
  region      = var.region
  prefix      = var.prefix
  alert_email = var.alert_email
}
