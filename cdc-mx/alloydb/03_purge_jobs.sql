-- =============================================================================
-- AlloyDB schema 03: jobs de retención y mantenimiento
-- Requiere extensión pg_cron habilitada via flag de cluster.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- -----------------------------------------------------------------------------
-- Job 1: hard delete de filas con is_deleted=TRUE > 30 días
-- Después de 30 días asumimos que el delete está consolidado en BQ y no
-- necesitamos más la "lápida" en AlloyDB.
-- -----------------------------------------------------------------------------
SELECT cron.schedule(
    'purge-deleted-customers',
    '0 3 * * *',  -- 03:00 todos los días
    $$ DELETE FROM app.customers
       WHERE is_deleted = TRUE
         AND cdc_received_at < NOW() - INTERVAL '30 days' $$
);

SELECT cron.schedule(
    'purge-deleted-orders',
    '5 3 * * *',
    $$ DELETE FROM app.orders
       WHERE is_deleted = TRUE
         AND cdc_received_at < NOW() - INTERVAL '30 days' $$
);

SELECT cron.schedule(
    'purge-deleted-items',
    '10 3 * * *',
    $$ DELETE FROM app.order_items
       WHERE is_deleted = TRUE
         AND cdc_received_at < NOW() - INTERVAL '30 days' $$
);

-- -----------------------------------------------------------------------------
-- Job 2: VACUUM FULL semanal en tablas con alta tasa de UPDATE
-- (mantiene bloat bajo control)
-- -----------------------------------------------------------------------------
SELECT cron.schedule(
    'vacuum-customers',
    '0 4 * * 0',  -- domingo 04:00
    $$ VACUUM (ANALYZE) app.customers $$
);

SELECT cron.schedule(
    'vacuum-orders',
    '15 4 * * 0',
    $$ VACUUM (ANALYZE) app.orders $$
);

-- -----------------------------------------------------------------------------
-- Job 3: refresco de stats para optimizer
-- -----------------------------------------------------------------------------
SELECT cron.schedule(
    'analyze-app',
    '0 */6 * * *',  -- cada 6 horas
    $$ ANALYZE app.customers, app.orders, app.order_items $$
);

-- -----------------------------------------------------------------------------
-- Job 4: cancelación física de consent_log retirados > 5 años
-- Después de 5 años el evidence ya cumplió. Hard delete con audit log.
-- -----------------------------------------------------------------------------
-- NOTA: requiere primero deshabilitar el trigger de no-delete en una
-- transacción controlada. NO automatizado por seguridad.
-- Mejor manualmente cuando el legal lo apruebe.

-- -----------------------------------------------------------------------------
-- Job 5: alerta diaria de SLA ARCO en riesgo
-- Inserta en una tabla que monitoring lee
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS compliance.sla_alerts (
    alert_id SERIAL PRIMARY KEY,
    request_id BIGINT NOT NULL,
    sla_status VARCHAR(20),
    hours_remaining FLOAT,
    alerted_at TIMESTAMPTZ DEFAULT NOW()
);

SELECT cron.schedule(
    'arco-sla-check',
    '0 9 * * *',  -- 09:00 todos los días
    $$ INSERT INTO compliance.sla_alerts (request_id, sla_status, hours_remaining)
       SELECT request_id, sla_status, hours_remaining
       FROM compliance.v_arco_at_risk
       WHERE sla_status IN ('CRITICAL', 'BREACHED') $$
);

-- -----------------------------------------------------------------------------
-- Verificación: listar jobs configurados
-- -----------------------------------------------------------------------------
SELECT jobid, schedule, command, jobname
FROM cron.job
ORDER BY jobname;
