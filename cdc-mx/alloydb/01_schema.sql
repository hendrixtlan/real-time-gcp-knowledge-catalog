-- =============================================================================
-- AlloyDB schema 01: tablas de dominio
-- Aplicar después de que el cluster esté READY.
-- =============================================================================

-- Extensiones útiles
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS google_columnar_engine;
CREATE EXTENSION IF NOT EXISTS google_db_advisor;

-- -----------------------------------------------------------------------------
-- Schema separado para datos de aplicación
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS app;

-- =============================================================================
-- Tablas de dominio
-- Cada tabla replicada de Oracle incluye campos CDC:
--   cdc_scn          — Oracle System Change Number (idempotencia)
--   cdc_op_ts        — timestamp del commit en Oracle
--   cdc_received_at  — timestamp cuando AlloyDB lo recibió (para medir lag)
--   is_deleted       — true si el último op fue DELETE (soft delete)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- customers
-- -----------------------------------------------------------------------------
CREATE TABLE app.customers (
    customer_id      BIGINT       PRIMARY KEY,
    email            VARCHAR(320),
    phone            VARCHAR(20),
    first_name       VARCHAR(100),
    last_name        VARCHAR(100),
    country_code     CHAR(2),
    created_at       TIMESTAMPTZ,
    updated_at       TIMESTAMPTZ,

    -- CDC metadata
    cdc_scn          BIGINT       NOT NULL,
    cdc_op_ts        TIMESTAMPTZ  NOT NULL,
    cdc_received_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    is_deleted       BOOLEAN      NOT NULL DEFAULT FALSE
);

CREATE INDEX ix_customers_email ON app.customers (email) WHERE NOT is_deleted;
CREATE INDEX ix_customers_updated ON app.customers (updated_at) WHERE NOT is_deleted;

COMMENT ON TABLE app.customers IS
    'Réplica CDC de APP_SCHEMA.CUSTOMERS de Oracle. SoT es Oracle.';
COMMENT ON COLUMN app.customers.cdc_scn IS
    'Oracle SCN del commit. Usado para guard de idempotencia en upserts.';

-- -----------------------------------------------------------------------------
-- orders
-- -----------------------------------------------------------------------------
CREATE TABLE app.orders (
    order_id         BIGINT       PRIMARY KEY,
    customer_id      BIGINT       NOT NULL,
    order_status     VARCHAR(20),
    total_amount     NUMERIC(12,2),
    currency         CHAR(3),
    placed_at        TIMESTAMPTZ,
    updated_at       TIMESTAMPTZ,

    cdc_scn          BIGINT       NOT NULL,
    cdc_op_ts        TIMESTAMPTZ  NOT NULL,
    cdc_received_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    is_deleted       BOOLEAN      NOT NULL DEFAULT FALSE
);

CREATE INDEX ix_orders_customer ON app.orders (customer_id, placed_at DESC) WHERE NOT is_deleted;
CREATE INDEX ix_orders_status ON app.orders (order_status, placed_at) WHERE NOT is_deleted;
CREATE INDEX ix_orders_placed ON app.orders (placed_at);

-- -----------------------------------------------------------------------------
-- order_items
-- -----------------------------------------------------------------------------
CREATE TABLE app.order_items (
    item_id          BIGINT       PRIMARY KEY,
    order_id         BIGINT       NOT NULL,
    product_id       BIGINT       NOT NULL,
    quantity         INTEGER,
    unit_price       NUMERIC(12,2),

    cdc_scn          BIGINT       NOT NULL,
    cdc_op_ts        TIMESTAMPTZ  NOT NULL,
    cdc_received_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    is_deleted       BOOLEAN      NOT NULL DEFAULT FALSE
);

CREATE INDEX ix_items_order ON app.order_items (order_id) WHERE NOT is_deleted;
CREATE INDEX ix_items_product ON app.order_items (product_id) WHERE NOT is_deleted;

-- =============================================================================
-- Función de upsert con SCN guard (idempotencia)
-- Llamada por Dataflow para cada evento CDC.
-- =============================================================================

CREATE OR REPLACE FUNCTION app.upsert_customer(
    p_customer_id BIGINT,
    p_email VARCHAR,
    p_phone VARCHAR,
    p_first_name VARCHAR,
    p_last_name VARCHAR,
    p_country_code CHAR,
    p_created_at TIMESTAMPTZ,
    p_updated_at TIMESTAMPTZ,
    p_cdc_scn BIGINT,
    p_cdc_op_ts TIMESTAMPTZ,
    p_op CHAR  -- 'I', 'U', 'D'
) RETURNS BOOLEAN AS $$
DECLARE
    v_applied BOOLEAN := FALSE;
BEGIN
    INSERT INTO app.customers (
        customer_id, email, phone, first_name, last_name, country_code,
        created_at, updated_at, cdc_scn, cdc_op_ts, cdc_received_at, is_deleted
    ) VALUES (
        p_customer_id, p_email, p_phone, p_first_name, p_last_name, p_country_code,
        p_created_at, p_updated_at, p_cdc_scn, p_cdc_op_ts, NOW(), (p_op = 'D')
    )
    ON CONFLICT (customer_id) DO UPDATE SET
        email           = EXCLUDED.email,
        phone           = EXCLUDED.phone,
        first_name      = EXCLUDED.first_name,
        last_name       = EXCLUDED.last_name,
        country_code    = EXCLUDED.country_code,
        created_at      = EXCLUDED.created_at,
        updated_at      = EXCLUDED.updated_at,
        cdc_scn         = EXCLUDED.cdc_scn,
        cdc_op_ts       = EXCLUDED.cdc_op_ts,
        cdc_received_at = EXCLUDED.cdc_received_at,
        is_deleted      = EXCLUDED.is_deleted
    -- SCN guard: solo aplicar si el evento es más reciente
    WHERE app.customers.cdc_scn < EXCLUDED.cdc_scn;

    GET DIAGNOSTICS v_applied = ROW_COUNT;
    RETURN v_applied;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION app.upsert_order(
    p_order_id BIGINT,
    p_customer_id BIGINT,
    p_order_status VARCHAR,
    p_total_amount NUMERIC,
    p_currency CHAR,
    p_placed_at TIMESTAMPTZ,
    p_updated_at TIMESTAMPTZ,
    p_cdc_scn BIGINT,
    p_cdc_op_ts TIMESTAMPTZ,
    p_op CHAR
) RETURNS BOOLEAN AS $$
DECLARE
    v_applied BOOLEAN := FALSE;
BEGIN
    INSERT INTO app.orders (
        order_id, customer_id, order_status, total_amount, currency,
        placed_at, updated_at, cdc_scn, cdc_op_ts, cdc_received_at, is_deleted
    ) VALUES (
        p_order_id, p_customer_id, p_order_status, p_total_amount, p_currency,
        p_placed_at, p_updated_at, p_cdc_scn, p_cdc_op_ts, NOW(), (p_op = 'D')
    )
    ON CONFLICT (order_id) DO UPDATE SET
        customer_id     = EXCLUDED.customer_id,
        order_status    = EXCLUDED.order_status,
        total_amount    = EXCLUDED.total_amount,
        currency        = EXCLUDED.currency,
        placed_at       = EXCLUDED.placed_at,
        updated_at      = EXCLUDED.updated_at,
        cdc_scn         = EXCLUDED.cdc_scn,
        cdc_op_ts       = EXCLUDED.cdc_op_ts,
        cdc_received_at = EXCLUDED.cdc_received_at,
        is_deleted      = EXCLUDED.is_deleted
    WHERE app.orders.cdc_scn < EXCLUDED.cdc_scn;

    GET DIAGNOSTICS v_applied = ROW_COUNT;
    RETURN v_applied;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION app.upsert_order_item(
    p_item_id BIGINT,
    p_order_id BIGINT,
    p_product_id BIGINT,
    p_quantity INTEGER,
    p_unit_price NUMERIC,
    p_cdc_scn BIGINT,
    p_cdc_op_ts TIMESTAMPTZ,
    p_op CHAR
) RETURNS BOOLEAN AS $$
DECLARE
    v_applied BOOLEAN := FALSE;
BEGIN
    INSERT INTO app.order_items (
        item_id, order_id, product_id, quantity, unit_price,
        cdc_scn, cdc_op_ts, cdc_received_at, is_deleted
    ) VALUES (
        p_item_id, p_order_id, p_product_id, p_quantity, p_unit_price,
        p_cdc_scn, p_cdc_op_ts, NOW(), (p_op = 'D')
    )
    ON CONFLICT (item_id) DO UPDATE SET
        order_id        = EXCLUDED.order_id,
        product_id      = EXCLUDED.product_id,
        quantity        = EXCLUDED.quantity,
        unit_price      = EXCLUDED.unit_price,
        cdc_scn         = EXCLUDED.cdc_scn,
        cdc_op_ts       = EXCLUDED.cdc_op_ts,
        cdc_received_at = EXCLUDED.cdc_received_at,
        is_deleted      = EXCLUDED.is_deleted
    WHERE app.order_items.cdc_scn < EXCLUDED.cdc_scn;

    GET DIAGNOSTICS v_applied = ROW_COUNT;
    RETURN v_applied;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- Vistas para la app (excluyendo soft-deleted)
-- =============================================================================
CREATE VIEW app.v_customers AS
    SELECT * FROM app.customers WHERE NOT is_deleted;

CREATE VIEW app.v_orders AS
    SELECT * FROM app.orders WHERE NOT is_deleted;

CREATE VIEW app.v_order_items AS
    SELECT * FROM app.order_items WHERE NOT is_deleted;

-- =============================================================================
-- Roles
-- =============================================================================
CREATE ROLE cdc_writer NOLOGIN;
GRANT USAGE ON SCHEMA app TO cdc_writer;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA app TO cdc_writer;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA app TO cdc_writer;

CREATE ROLE app_reader NOLOGIN;
GRANT USAGE ON SCHEMA app TO app_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA app TO app_reader;

-- Usuarios concretos: crearlos vía gcloud y asignar roles
-- gcloud alloydb users create dataflow_writer --cluster=... --password=... --type=ALLOYDB_BUILT_IN
-- Luego: GRANT cdc_writer TO dataflow_writer;
