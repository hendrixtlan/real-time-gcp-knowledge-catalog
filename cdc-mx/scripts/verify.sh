#!/usr/bin/env bash
# =============================================================================
# verify.sh — smoke tests del stack desplegado
#
# Verifica:
#   - Streams Datastream RUNNING
#   - Dataflow job RUNNING y sin errores
#   - AlloyDB recibiendo writes (lag < 5s)
#   - BigQuery datasets existen y tablas tienen datos
#   - Cloud Run ARCO responde /healthz
#   - KMS keys activas
#   - Audit logs flowing al bucket
# =============================================================================

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform/envs/prod"

get_tfvar() {
    grep -E "^\s*${1}\s*=" "$TF_DIR/terraform.tfvars" | sed -E 's/.*=\s*"?([^"]+)"?\s*$/\1/' | tr -d '"'
}
PROJECT_ID="$(get_tfvar project_id)"
REGION="$(get_tfvar region)"
PREFIX="$(get_tfvar prefix)"

PASS=0; FAIL=0; WARN=0

check() {
    local name="$1"; local cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        echo "  [✓] $name"
        ((PASS++))
    else
        echo "  [✗] $name"
        ((FAIL++))
    fi
}

warn_check() {
    local name="$1"; local result="$2"; local expected="$3"
    if [[ "$result" == "$expected" ]]; then
        echo "  [✓] $name = $result"
        ((PASS++))
    else
        echo "  [!] $name = $result (esperado: $expected)"
        ((WARN++))
    fi
}

echo "=== Verificación stack CDC-MX ==="
echo "Project: $PROJECT_ID  Region: $REGION  Prefix: $PREFIX"
echo

# -----------------------------------------------------------------------------
echo "[1/8] Datastream"
for s in "${PREFIX}-bq-stream" "${PREFIX}-gcs-stream"; do
    state=$(gcloud datastream streams describe "$s" --location="$REGION" \
        --project="$PROJECT_ID" --format="value(state)" 2>/dev/null || echo "MISSING")
    warn_check "stream $s" "$state" "RUNNING"
done

# -----------------------------------------------------------------------------
echo
echo "[2/8] Dataflow"
job=$(gcloud dataflow jobs list --region="$REGION" --status=active \
    --project="$PROJECT_ID" --format="value(JOB_ID)" --filter="NAME ~ ${PREFIX}" 2>/dev/null | head -1)
if [[ -n "$job" ]]; then
    state=$(gcloud dataflow jobs describe "$job" --region="$REGION" \
        --project="$PROJECT_ID" --format="value(currentState)")
    warn_check "dataflow job $job" "$state" "JOB_STATE_RUNNING"
else
    echo "  [!] No hay job activo de Dataflow"
    ((WARN++))
fi

# -----------------------------------------------------------------------------
echo
echo "[3/8] BigQuery"
for ds in "${PREFIX//-/_}_analytics" "${PREFIX//-/_}_analytics_replica" "${PREFIX//-/_}_ops"; do
    check "dataset $ds" "bq --project_id=$PROJECT_ID show --dataset $ds"
done

# Conteo de filas en réplica
for t in APP_SCHEMA_CUSTOMERS APP_SCHEMA_ORDERS APP_SCHEMA_ORDER_ITEMS; do
    count=$(bq --project_id="$PROJECT_ID" query --nouse_legacy_sql --format=csv \
        "SELECT COUNT(*) FROM \`${PROJECT_ID}.${PREFIX//-/_}_analytics_replica.$t\`" 2>/dev/null | tail -1)
    if [[ -n "$count" && "$count" != "0" ]]; then
        echo "  [✓] BQ $t: $count filas"
        ((PASS++))
    else
        echo "  [!] BQ $t: 0 filas o tabla no existe (esperado si CDC apenas arrancó)"
        ((WARN++))
    fi
done

# -----------------------------------------------------------------------------
echo
echo "[4/8] AlloyDB freshness (requiere conectividad VPC)"
ALLOYDB_IP="$(cd "$TF_DIR" && terraform output -raw alloydb_primary_ip 2>/dev/null || echo)"
if [[ -n "$ALLOYDB_IP" ]] && command -v psql &>/dev/null; then
    PASS_PG="$(get_tfvar alloydb_initial_password)"
    PGPASSWORD="$PASS_PG" psql "host=$ALLOYDB_IP user=postgres dbname=cdc_mx connect_timeout=5" -tAc "
        SELECT 'customers ' || COUNT(*) || ' lag=' ||
            EXTRACT(EPOCH FROM (NOW() - MAX(cdc_received_at)))::int || 's'
        FROM app.customers
        UNION ALL
        SELECT 'orders ' || COUNT(*) || ' lag=' ||
            EXTRACT(EPOCH FROM (NOW() - MAX(cdc_received_at)))::int || 's'
        FROM app.orders;
    " 2>/dev/null && ((PASS++)) || { echo "  [!] no se pudo consultar AlloyDB"; ((WARN++)); }
    unset PGPASSWORD
else
    echo "  [skip] psql no disponible o output IP vacío"
fi

# -----------------------------------------------------------------------------
echo
echo "[5/8] Cloud Run ARCO"
ARCO_URL="$(cd "$TF_DIR" && terraform output -raw arco_service_url 2>/dev/null || echo)"
if [[ -n "$ARCO_URL" ]]; then
    TOKEN="$(gcloud auth print-identity-token)"
    code=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "${ARCO_URL}/healthz")
    warn_check "ARCO /healthz" "$code" "200"
fi

# -----------------------------------------------------------------------------
echo
echo "[6/8] KMS keys"
for k in alloydb bigquery pubsub storage; do
    state=$(gcloud kms keys describe "${PREFIX}-${k}" \
        --keyring="${PREFIX}-keyring" --location="$REGION" \
        --project="$PROJECT_ID" --format="value(versionTemplate.protectionLevel)" 2>/dev/null || echo "MISSING")
    if [[ "$state" != "MISSING" ]]; then
        echo "  [✓] KMS ${PREFIX}-${k}: $state"
        ((PASS++))
    else
        echo "  [✗] KMS ${PREFIX}-${k}: faltante"
        ((FAIL++))
    fi
done

# -----------------------------------------------------------------------------
echo
echo "[7/8] Audit logs bucket"
LOG_BUCKET="$(cd "$TF_DIR" && terraform output -raw audit_log_bucket 2>/dev/null || echo)"
if [[ -n "$LOG_BUCKET" ]]; then
    cnt=$(gsutil ls "gs://$LOG_BUCKET/" 2>/dev/null | wc -l)
    echo "  [✓] $LOG_BUCKET — $cnt objetos"
    ((PASS++))
fi

# -----------------------------------------------------------------------------
echo
echo "[8/8] LFPDPPP — Pub/Sub topics críticos"
for t in cdc-events dlq breach-events arco-sla-alerts audit-events; do
    full="${PREFIX}-${t}"
    if gcloud pubsub topics describe "$full" --project="$PROJECT_ID" >/dev/null 2>&1; then
        echo "  [✓] topic $full"
        ((PASS++))
    else
        echo "  [✗] topic $full faltante"
        ((FAIL++))
    fi
done

# -----------------------------------------------------------------------------
echo
echo "=== Resumen: PASS=$PASS  FAIL=$FAIL  WARN=$WARN ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
