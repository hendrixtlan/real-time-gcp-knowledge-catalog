# Backend GCS para state remoto.
# El bucket lo crea scripts/deploy.sh init antes del primer apply.

terraform {
  backend "gcs" {
    # bucket se pasa via -backend-config="bucket=PROJECT_ID-tfstate"
    prefix = "cdc-mx/prod"
  }
}
