# Runbook de operación

Procedimientos para deploy, troubleshooting y respuesta a incidentes.

## Deploy inicial

### Pre-requisitos

```bash
# Verificar versiones
gcloud --version          # >= 460
terraform --version       # >= 1.5
python3 --version         # >= 3.10
docker --version          # cualquier versión reciente

# Variables base
export PROJECT_ID="mi-proyecto-cdc"
export REGION="northamerica-south1"
export ORACLE_HOST="10.0.0.50"  # IP alcanzable desde GCP
export ALERT_EMAIL="ops@miempresa.mx"
```

### Paso 1: APIs y permisos

```bash
gcloud auth login
gcloud config set project $PROJECT_ID

# El usuario que corre Terraform necesita estos roles a nivel proyecto
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="user:$(gcloud config get-value account)" \
  --role="roles/owner"
```

### Paso 2: Preparación de Oracle

Esta parte ocurre on-premise.

```sql
-- como SYSDBA
@oracle/setup.sql
-- reemplaza el password placeholder antes de correr
```

Verifica:

```sql
SELECT log_mode FROM v$database;
-- esperado: ARCHIVELOG

SELECT supplemental_log_data_min, supplemental_log_data_pk
FROM v$database;
-- esperado: YES, YES
```

### Paso 3: Setup inicial GCP

```bash
./scripts/deploy.sh init
```

Esto crea:
- Bucket GCS para Terraform state
- Secrets en Secret Manager (Oracle password, AlloyDB password)
- Habilita APIs requeridas

### Paso 4: Build de imágenes Docker

```bash
./scripts/deploy.sh build
```

Construye y sube a Artifact Registry:
- `cdc-mx/dataflow-serving:latest`
- `cdc-mx/arco-service:latest`
- `cdc-mx/reconciliation-service:latest`

### Paso 5: Terraform apply

```bash
cd terraform/envs/prod
terraform init -backend-config="bucket=${PROJECT_ID}-tfstate"
terraform plan -out=tfplan
# revisar el plan, debe crear ~80 recursos
terraform apply tfplan
```

Tarda 20-30 minutos. AlloyDB cluster es lo más lento (~15 min).

### Paso 6: Schemas

```bash
./scripts/deploy.sh schema
```

Aplica:
- AlloyDB: `01_schema.sql`, `02_compliance.sql`, `03_purge_jobs.sql`
- BigQuery: `01_setup.sql`, `02_views.sql`

### Paso 7: Verificación

```bash
./scripts/verify.sh
```

Health checks:
- Datastream stream RUNNING
- AlloyDB cluster READY
- Dataflow job RUNNING
- ARCO service responde 200 en `/health`
- Reconciliation service responde 200
- `compliance_check.py` pasa todos los asserts

## Operación diaria

### Monitoreo

Dashboards principales en Cloud Monitoring:

- **CDC End-to-End Lag** — lag desde Oracle commit hasta visible en cada sink
- **AlloyDB Performance** — CPU, conexiones, queries lentas
- **Pub/Sub Backlog** — mensajes sin procesar en cada subscription
- **DLQ Activity** — mensajes en dead-letter queues
- **ARCO SLA** — solicitudes próximas a vencer

Alertas críticas (van a `$ALERT_EMAIL`):

| Alerta                              | Threshold        | Severidad |
|-------------------------------------|------------------|-----------|
| Datastream lag p99 > 30s             | 5 min sustained  | Warning   |
| Dataflow system lag > 60s            | 5 min            | Warning   |
| AlloyDB CPU > 80%                    | 5 min            | Warning   |
| DLQ con mensajes                     | 1 min            | Warning   |
| ARCO request a < 24h del SLA         | inmediata        | Critical  |
| Audit log sink falla                 | 5 min            | Critical  |
| Brecha detectada                     | inmediata        | Critical  |

### Reconciliación

Corre cada hora vía Cloud Scheduler. Revisa logs:

```bash
gcloud logging read \
  "resource.type=cloud_run_revision \
   AND resource.labels.service_name=cdc-mx-reconciliation \
   AND severity>=WARNING" \
  --limit=20 --format=json
```

Si una reconciliación reporta divergencia > 0.1%, investiga:

1. Verifica que Datastream esté corriendo (no en pausa o backfilling)
2. Verifica DLQs por mensajes perdidos
3. Compara MAX(updated_at) en Oracle vs BQ vs AlloyDB
4. Si diferencia es solo en lag (Oracle adelantado), espera 15 min y revisa
5. Si persiste, considera replay desde GCS

### Replay desde GCS

Si necesitas reprocesar eventos:

```bash
# Identificar timestamp del último evento procesado correctamente
SUBSCRIPTION="cdc-mx-serving-sub"
gcloud pubsub subscriptions seek $SUBSCRIPTION \
  --time="2025-12-01T10:00:00Z"
```

Cuidado: si tu job ya procesó eventos posteriores y el SCN guard ya los
tiene, el replay no causará duplicados (es idempotente). Pero sí re-aplicará
los eventos antiguos que ya estaban procesados, lo cual es lento.

Para replay controlado, mejor pausar el job, hacer seek, y reanudar.

## Troubleshooting

### Datastream stream FAILED

Posibles causas:

1. **Conectividad Oracle**
   ```bash
   gcloud datastream streams describe STREAM_ID --location=$REGION
   # buscar errors en state.errors
   ```

2. **Privilegios del usuario CDC**
   ```sql
   -- en Oracle, como SYS
   SELECT * FROM dba_role_privs WHERE grantee='DATASTREAM_CDC';
   SELECT * FROM dba_sys_privs WHERE grantee='DATASTREAM_CDC';
   ```
   Re-ejecuta `oracle/setup.sql` si falta algo.

3. **Supplemental logging deshabilitado**
   ```sql
   SELECT supplemental_log_data_pk FROM v$database;
   -- debe ser YES
   ```

4. **Archive log lleno**
   ```sql
   SELECT * FROM v$flash_recovery_area_usage;
   ```
   Solicitar al DBA limpieza del FRA.

### Dataflow job atrasado (system lag alto)

```bash
# Identificar bottleneck
gcloud dataflow jobs describe JOB_ID --region=$REGION

# Si es CPU saturado, escalar workers
# (modificar terraform var dataflow_max_workers y apply)
```

Si el cuello es AlloyDB writes:
- Subir CPU del primary
- Aumentar `upsert_batch_size` en el job (más rows por upsert)
- Verificar que las queries usen los índices esperados

### AlloyDB connections agotadas

```sql
SELECT count(*), state FROM pg_stat_activity GROUP BY state;
```

Si hay muchas en `idle`, el connection pool no está configurado bien.
Verificar PgBouncer en transaction mode.

### ARCO service responde lento

Causa común: query de export a BigQuery de un titular con mucho histórico.

Mitigación:
- Particionar el export por año (signed URLs separados)
- Usar BQ EXPORT DATA con compression

## Respuesta a incidentes

### Brecha detectada

1. **Confirmar:** verificar que la alerta no es falso positivo
   (ejemplo: backfill legítimo de un equipo de analytics)

2. **Contener:** revocar credenciales comprometidas, bloquear IP origen

3. **Notificar internamente:**
   ```bash
   curl -X POST https://arco-service-XXX.run.app/arco/breach-notify \
     -H "Content-Type: application/json" \
     -d '{
       "severity": "HIGH",
       "affected_systems": ["alloydb-customers"],
       "estimated_records_affected": 12500,
       "data_categories": ["EMAIL", "PHONE"],
       "discovered_by": "alerta cloud-monitoring",
       "description": "Acceso anómalo desde IP no whitelisted"
     }'
   ```
   Esto registra el incidente y publica al topic `lfpdppp-data-breach-events`.

4. **Notificar a titulares:** el playbook automático del breach-response
   service identifica titulares afectados y dispara emails. Plazo
   recomendado: 72h desde confirmación.

5. **Documentar para Secretaría:** preserva audit logs, timestamps,
   acciones tomadas. Mantener 5 años (CFF + LFPDPPP).

### Solicitud ARCO recibida

El proceso típico:

1. Frontend / customer service recibe la solicitud
2. Verifica identidad del titular (INE, contraseña, OTP, etc.)
3. Llama al endpoint correspondiente con `identity_verified=true`
4. El servicio resuelve y devuelve resultado

Si la solicitud llega al límite del SLA sin resolver:

```bash
gcloud logging read \
  "jsonPayload.event_type=ARCO_SLA_CRITICAL" \
  --limit=10
```

### Pérdida de datos en AlloyDB

```bash
# Listar backups disponibles
gcloud alloydb backups list --region=$REGION

# PITR (Point-in-Time Recovery) — hasta 7 días atrás
gcloud alloydb clusters restore RESTORED_CLUSTER_ID \
  --source-cluster-id=ORIGINAL_ID \
  --point-in-time="2025-12-01T10:00:00Z" \
  --region=$REGION
```

Consideración LFPDPPP: notificar a titulares afectados si el incidente
afectó "significativamente sus derechos" (Art. 20).

## Cambios de schema

Cuando un equipo de aplicación agrega una columna en Oracle:

1. **Coordinar con DBA:** asegurar `ALTER TABLE ... ADD SUPPLEMENTAL LOG
   DATA (ALL) COLUMNS` aplicado a la nueva columna.

2. **Verificar Datastream:** absorber el cambio automáticamente al BQ
   (con `allowFieldAddition`).

3. **Aplicar manualmente a AlloyDB:**
   ```sql
   ALTER TABLE customers ADD COLUMN nueva_columna VARCHAR(100);
   ```

4. **Actualizar Dataflow job:** agregar la columna al `TABLE_MAPPINGS` en
   `dataflow/serving/main.py` y redeploy.

5. **Actualizar aspect types:** si la columna es PII, marcarla con
   `pii-classification` y aplicar policy tag.

6. **Compliance check:** correr `scripts/compliance_check.py` para validar.

## Decommission

Si necesitas desmontar el stack:

```bash
# 1. Drain Dataflow jobs
gcloud dataflow jobs drain JOB_ID --region=$REGION

# 2. Pausar Datastream
gcloud datastream streams update STREAM_ID --location=$REGION --state=PAUSED

# 3. Backup AlloyDB final
gcloud alloydb backups create final-backup --cluster=CLUSTER_ID --region=$REGION

# 4. Export BigQuery final
bq extract --destination_format=PARQUET \
  "$PROJECT_ID:analytics.customers" \
  "gs://archive-bucket/final/customers/*.parquet"

# 5. Terraform destroy (cuidado con prevent_destroy en KMS keys)
cd terraform/envs/prod
terraform destroy
```

**LFPDPPP:** antes de destruir, asegurar que se han atendido todas las
solicitudes ARCO pendientes y que se ha notificado a titulares de la
discontinuación del servicio si aplica.
