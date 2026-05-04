-- =============================================================================
-- BigQuery setup
-- Las tablas analytics.* las crea Datastream automáticamente.
-- Aquí configuramos vistas y políticas adicionales.
-- =============================================================================

-- Reemplazar PROJECT_ID al ejecutar
DECLARE project_id STRING DEFAULT 'REEMPLAZAR_PROJECT_ID';

-- =============================================================================
-- Aplicar policy tags a columnas PII en las tablas que crea Datastream
-- (esto se aplica DESPUÉS del primer backfill, cuando las tablas existen)
-- =============================================================================

-- Ejemplo customers: marcar email como PII media
-- En realidad se hace via el módulo terraform/modules/catalog o via API
-- ALTER TABLE `analytics.APP_SCHEMA_CUSTOMERS`
--   ALTER COLUMN email
--   SET OPTIONS (
--     description = "Email del cliente. PII media. LFPDPPP datos personales.",
--     policy_tags = STRUCT(["projects/PROJECT_ID/locations/.../taxonomies/.../policyTags/..."])
--   );

-- =============================================================================
-- Configurar partition_expiration en tablas CDC
-- Datastream crea las tablas pero no setea expiration. Aplicamos política.
-- =============================================================================

-- Las tablas CDC de Datastream tienen el formato schema_table
-- Aplicar después del primer ingest:
-- ALTER TABLE `analytics.APP_SCHEMA_CUSTOMERS`
--   SET OPTIONS (
--     partition_expiration_days = 1825,  -- 5 años
--     require_partition_filter = TRUE,
--     description = "CDC de APP_SCHEMA.CUSTOMERS. Retención 5 años por CFF."
--   );

-- =============================================================================
-- Vista ops: lag CDC end-to-end por tabla
-- =============================================================================
CREATE OR REPLACE VIEW `ops.v_cdc_lag_summary` AS
SELECT
    table_name,
    sink,
    COUNT(*) AS sample_count,
    AVG(lag_ms) AS avg_lag_ms,
    APPROX_QUANTILES(lag_ms, 100)[OFFSET(50)] AS p50_lag_ms,
    APPROX_QUANTILES(lag_ms, 100)[OFFSET(95)] AS p95_lag_ms,
    APPROX_QUANTILES(lag_ms, 100)[OFFSET(99)] AS p99_lag_ms,
    MAX(lag_ms) AS max_lag_ms,
    MIN(received_at) AS sample_window_start,
    MAX(received_at) AS sample_window_end
FROM `ops.cdc_lag`
WHERE received_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)
GROUP BY table_name, sink;

-- =============================================================================
-- Vista ops: estado de SLA ARCO
-- =============================================================================
CREATE OR REPLACE VIEW `ops.v_arco_sla_status` AS
SELECT
    request_type,
    COUNT(*) AS total,
    COUNTIF(deadline_breached) AS breached,
    COUNTIF(NOT deadline_breached AND resolved_at IS NULL) AS open,
    AVG(sla_hours_used) AS avg_resolution_hours,
    APPROX_QUANTILES(sla_hours_used, 100)[OFFSET(95)] AS p95_resolution_hours,
    DATE_TRUNC(submitted_at, MONTH) AS month
FROM `ops.arco_audit`
WHERE submitted_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 12 MONTH)
GROUP BY request_type, month;

-- =============================================================================
-- Política de acceso a datos en analytics
-- Solo data_analysts (rol custom) pueden leer; nadie puede modificar
-- =============================================================================
-- GRANT `roles/bigquery.dataViewer`
-- ON SCHEMA `analytics`
-- TO 'group:data-analysts@miempresa.mx';

-- =============================================================================
-- Reservación de slots (opcional, para cargas predecibles)
-- =============================================================================
-- CREATE CAPACITY ... AS JOB ...
-- CREATE RESERVATION ...
-- CREATE ASSIGNMENT ...
