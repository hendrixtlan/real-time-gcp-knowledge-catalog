-- =============================================================================
-- Setup Oracle para Datastream CDC
-- Ejecutar como SYSDBA en la base origen
-- =============================================================================

-- IMPORTANTE: reemplazar el password antes de ejecutar
DEFINE datastream_password = 'REEMPLAZAR_CON_PASSWORD_FUERTE'

-- -----------------------------------------------------------------------------
-- 1. Verificar prerequisitos
-- -----------------------------------------------------------------------------
SELECT log_mode FROM v$database;
-- Si NO es ARCHIVELOG, requiere reinicio:
--   SHUTDOWN IMMEDIATE;
--   STARTUP MOUNT;
--   ALTER DATABASE ARCHIVELOG;
--   ALTER DATABASE OPEN;

-- Tamaño recomendado FRA: al menos 100 GB para CDC continuo
SELECT * FROM v$flash_recovery_area_usage;

-- -----------------------------------------------------------------------------
-- 2. Habilitar supplemental logging a nivel database
-- -----------------------------------------------------------------------------
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (PRIMARY KEY) COLUMNS;

-- Verificar
SELECT supplemental_log_data_min, supplemental_log_data_pk
FROM v$database;
-- Esperado: YES, YES

-- -----------------------------------------------------------------------------
-- 3. Crear usuario DATASTREAM_CDC con privilegios mínimos
-- -----------------------------------------------------------------------------
-- Si la BD es multi-tenant (CDB), conectarse al PDB primero:
--   ALTER SESSION SET CONTAINER = ORCLPDB1;

CREATE USER DATASTREAM_CDC IDENTIFIED BY "&datastream_password"
    DEFAULT TABLESPACE USERS
    QUOTA UNLIMITED ON USERS;

-- Privilegios para ver el catalog y los datos
GRANT CREATE SESSION TO DATASTREAM_CDC;
GRANT SELECT ON DBA_OBJECTS TO DATASTREAM_CDC;
GRANT SELECT ON DBA_USERS TO DATASTREAM_CDC;
GRANT SELECT ON DBA_TAB_COLUMNS TO DATASTREAM_CDC;
GRANT SELECT ON DBA_CONSTRAINTS TO DATASTREAM_CDC;
GRANT SELECT ON DBA_CONS_COLUMNS TO DATASTREAM_CDC;
GRANT SELECT ON DBA_INDEXES TO DATASTREAM_CDC;
GRANT SELECT ON DBA_IND_COLUMNS TO DATASTREAM_CDC;
GRANT SELECT ON DBA_LOG_GROUPS TO DATASTREAM_CDC;
GRANT SELECT ON DBA_LOG_GROUP_COLUMNS TO DATASTREAM_CDC;
GRANT SELECT ON DBA_TAB_PARTITIONS TO DATASTREAM_CDC;
GRANT SELECT ON DBA_TAB_SUBPARTITIONS TO DATASTREAM_CDC;
GRANT SELECT ON DBA_NESTED_TABLES TO DATASTREAM_CDC;

-- Privilegios para LogMiner CDC
GRANT EXECUTE_CATALOG_ROLE TO DATASTREAM_CDC;
GRANT SELECT_CATALOG_ROLE TO DATASTREAM_CDC;
GRANT EXECUTE ON SYS.DBMS_LOGMNR TO DATASTREAM_CDC;
GRANT EXECUTE ON SYS.DBMS_LOGMNR_D TO DATASTREAM_CDC;
GRANT SELECT ON V_$DATABASE TO DATASTREAM_CDC;
GRANT SELECT ON V_$LOG TO DATASTREAM_CDC;
GRANT SELECT ON V_$LOGFILE TO DATASTREAM_CDC;
GRANT SELECT ON V_$ARCHIVED_LOG TO DATASTREAM_CDC;
GRANT SELECT ON V_$LOGMNR_CONTENTS TO DATASTREAM_CDC;
GRANT SELECT ON V_$LOGMNR_LOGS TO DATASTREAM_CDC;
GRANT SELECT ON V_$THREAD TO DATASTREAM_CDC;
GRANT SELECT ON V_$DATAFILE TO DATASTREAM_CDC;

-- 19c+ requiere LOGMINING
GRANT LOGMINING TO DATASTREAM_CDC;

-- -----------------------------------------------------------------------------
-- 4. Acceso a las tablas a replicar
-- -----------------------------------------------------------------------------
-- Modo simple: SELECT a nivel ANY (más permisivo)
-- GRANT SELECT ANY TABLE TO DATASTREAM_CDC;

-- Modo restrictivo (preferido): solo a las tablas específicas
GRANT SELECT ON APP_SCHEMA.CUSTOMERS TO DATASTREAM_CDC;
GRANT SELECT ON APP_SCHEMA.ORDERS TO DATASTREAM_CDC;
GRANT SELECT ON APP_SCHEMA.ORDER_ITEMS TO DATASTREAM_CDC;

-- -----------------------------------------------------------------------------
-- 5. Supplemental logging a nivel tabla
-- Necesario para captar UPDATEs completos (no solo PK + columnas modificadas)
-- -----------------------------------------------------------------------------
ALTER TABLE APP_SCHEMA.CUSTOMERS
    ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

ALTER TABLE APP_SCHEMA.ORDERS
    ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

ALTER TABLE APP_SCHEMA.ORDER_ITEMS
    ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- -----------------------------------------------------------------------------
-- 6. Verificación final
-- -----------------------------------------------------------------------------
-- Privilegios del usuario
SELECT * FROM dba_role_privs WHERE grantee = 'DATASTREAM_CDC';
SELECT * FROM dba_sys_privs WHERE grantee = 'DATASTREAM_CDC';
SELECT * FROM dba_tab_privs WHERE grantee = 'DATASTREAM_CDC';

-- Supplemental logging activo en las tablas
SELECT owner, log_group_name, table_name, always
FROM dba_log_groups
WHERE owner = 'APP_SCHEMA';

-- Espacio en FRA
SELECT * FROM v$flash_recovery_area_usage;

PROMPT ============================================================
PROMPT Setup Oracle completado.
PROMPT
PROMPT Próximos pasos:
PROMPT   1. Configurar conectividad GCP → Oracle (Cloud Interconnect/VPN)
PROMPT   2. Verificar firewall: GCP debe alcanzar puerto 1521
PROMPT   3. Continuar con scripts/deploy.sh init
PROMPT ============================================================

EXIT
