#!/usr/bin/env bash
# Construye y publica el Flex Template del job de serving.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID required}"
REGION="${REGION:-northamerica-south1}"
PREFIX="${PREFIX:-cdc-mx}"

REPO="northamerica-south1-docker.pkg.dev/${PROJECT_ID}/${PREFIX}"
IMAGE_URI="${REPO}/dataflow-serving:latest"

TEMPLATES_BUCKET="${PROJECT_ID}-${PREFIX}-templates"
TEMPLATE_FILE="gs://${TEMPLATES_BUCKET}/serving/template.json"

# Crear bucket si no existe
gsutil ls -b "gs://${TEMPLATES_BUCKET}" 2>/dev/null || \
    gsutil mb -p "${PROJECT_ID}" -l "${REGION}" "gs://${TEMPLATES_BUCKET}"

# Build & push image
echo "Building Docker image..."
gcloud builds submit \
    --project="${PROJECT_ID}" \
    --tag="${IMAGE_URI}" \
    "$(dirname "$0")"

# Build flex template
echo "Building flex template..."
gcloud dataflow flex-template build "${TEMPLATE_FILE}" \
    --project="${PROJECT_ID}" \
    --image="${IMAGE_URI}" \
    --sdk-language=PYTHON \
    --metadata-file="$(dirname "$0")/metadata.json"

echo ""
echo "Template built: ${TEMPLATE_FILE}"
echo "Use this path for terraform var dataflow_flex_template_gcs_path"
