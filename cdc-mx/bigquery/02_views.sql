-- =============================================================================
-- BigQuery vistas analíticas
-- Las tablas que crea Datastream tienen sufijo _CDC y aplican MERGE auto.
-- =============================================================================

-- =============================================================================
-- Vista: customers con datos enmascarados para analistas sin acceso a PII
-- Usa data masking de BQ con policy tags.
-- =============================================================================
-- Esto se configura via policy tags + IAM, no via SQL directamente.
-- Documentación: https://cloud.google.com/bigquery/docs/column-data-masking-intro

-- =============================================================================
-- Vista: pedidos con cliente joineado
-- =============================================================================
CREATE OR REPLACE VIEW `analytics.v_orders_enriched` AS
SELECT
    o.order_id,
    o.customer_id,
    c.country_code,
    o.order_status,
    o.total_amount,
    o.currency,
    o.placed_at,
    DATE(o.placed_at) AS placed_date,
    -- Excluimos PII directa (email, phone, nombres) en esta vista
FROM `analytics.APP_SCHEMA_ORDERS` o
LEFT JOIN `analytics.APP_SCHEMA_CUSTOMERS` c
    ON o.customer_id = c.customer_id;

-- =============================================================================
-- Vista: customer 360 (incluye PII, requiere acceso elevado)
-- =============================================================================
CREATE OR REPLACE VIEW `analytics.v_customer_360` AS
WITH order_stats AS (
    SELECT
        customer_id,
        COUNT(*) AS total_orders,
        SUM(total_amount) AS lifetime_value,
        MIN(placed_at) AS first_order_at,
        MAX(placed_at) AS last_order_at
    FROM `analytics.APP_SCHEMA_ORDERS`
    GROUP BY customer_id
)
SELECT
    c.customer_id,
    c.email,
    c.phone,
    c.first_name,
    c.last_name,
    c.country_code,
    c.created_at,
    COALESCE(s.total_orders, 0) AS total_orders,
    COALESCE(s.lifetime_value, 0) AS lifetime_value,
    s.first_order_at,
    s.last_order_at
FROM `analytics.APP_SCHEMA_CUSTOMERS` c
LEFT JOIN order_stats s USING (customer_id);

-- =============================================================================
-- Vista: actividad reciente para detectar acceso anómalo
-- =============================================================================
CREATE OR REPLACE VIEW `ops.v_data_access_recent` AS
SELECT
    timestamp AS access_at,
    protoPayload.authenticationInfo.principalEmail AS user_email,
    protoPayload.methodName AS method,
    protoPayload.resourceName AS resource,
    protoPayload.requestMetadata.callerIp AS source_ip,
    JSON_EXTRACT_SCALAR(
        protoPayload.metadata, '$.tableDataRead.fields'
    ) AS fields_accessed
FROM `PROJECT_ID.cloudaudit_googleapis_com_data_access_*`
WHERE _TABLE_SUFFIX BETWEEN
    FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY))
    AND FORMAT_DATE('%Y%m%d', CURRENT_DATE())
  AND protoPayload.serviceName = 'bigquery.googleapis.com'
  AND protoPayload.methodName IN (
    'jobservice.jobcompleted',
    'google.cloud.bigquery.v2.JobService.InsertJob'
  );

-- =============================================================================
-- Vista: detección de queries que extraen volumen anómalo de PII
-- =============================================================================
CREATE OR REPLACE VIEW `ops.v_pii_bulk_access_anomalies` AS
SELECT
    DATE(timestamp) AS access_date,
    protoPayload.authenticationInfo.principalEmail AS user_email,
    COUNT(*) AS query_count,
    SUM(CAST(JSON_EXTRACT_SCALAR(
        protoPayload.metadata, '$.jobChange.job.jobStats.totalProcessedBytes'
    ) AS INT64)) AS total_bytes_processed
FROM `PROJECT_ID.cloudaudit_googleapis_com_data_access_*`
WHERE _TABLE_SUFFIX BETWEEN
    FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY))
    AND FORMAT_DATE('%Y%m%d', CURRENT_DATE())
  AND protoPayload.serviceName = 'bigquery.googleapis.com'
  AND protoPayload.resourceName LIKE '%/datasets/analytics/%'
GROUP BY access_date, user_email
HAVING total_bytes_processed > 10737418240  -- > 10 GB
ORDER BY total_bytes_processed DESC;
