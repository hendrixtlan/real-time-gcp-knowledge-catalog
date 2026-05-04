# cdc-mx · Stack CDC Oracle → GCP con cumplimiento LFPDPPP 2025

Stack greenfield para replicación en tiempo real desde Oracle on-premise hacia
Google Cloud, diseñado desde el inicio para cumplir con la Nueva Ley Federal
de Protección de Datos Personales en Posesión de los Particulares (vigente
desde 21 de marzo de 2025; última reforma 14 de noviembre de 2025).

## Resumen ejecutivo

| Concepto                              | Valor                                    |
|---------------------------------------|------------------------------------------|
| Origen                                 | Oracle 19c+ on-premise                   |
| Región GCP                             | `northamerica-south1` (Querétaro)        |
| Latencia lectura app → AlloyDB (p99)   | < 50 ms                                  |
| Propagación CDC Oracle → AlloyDB       | 1-3 s típico                             |
| Propagación CDC Oracle → BigQuery      | 5-30 s (Datastream sink directo)         |
| SLA derechos ARCO                      | 20 días resolución, 15 días ejecución    |
| Costo estimado mensual (5 TB CDC)      | $5,800 - $7,200 USD                      |

## Arquitectura

```
┌─────────────────┐
│  Oracle OLTP    │  on-premise / Cloud Interconnect
│  (source)       │
└────────┬────────┘
         │ CDC vía LogMiner (supplemental logging)
         ▼
┌─────────────────┐
│   Datastream    │  managed CDC (1-2s pickup latency)
└────────┬────────┘
         │
    ┌────┴─────────────────────────┐
    │                              │
    ▼                              ▼
┌─────────────────┐      ┌─────────────────┐
│   BigQuery      │      │   GCS landing   │  Avro, file_rotation=15s
│   (CDC sink     │      │   (intermedio)  │
│    directo)     │      └────────┬────────┘
│                 │               │ notif
│   5-30s lag     │               ▼
│                 │      ┌─────────────────┐
│   Particionado  │      │   Pub/Sub       │  ordering key = PK
│   con CMEK      │      │   (CMEK)        │  exactly-once
└─────────────────┘      └────────┬────────┘
                                  │
                                  ▼
                         ┌─────────────────┐
                         │   Dataflow      │  streaming engine
                         │   (serving)     │  trigger=1s, batch=100
                         └────────┬────────┘
                                  │ upsert idempotente (SCN guard)
                                  ▼
                         ┌─────────────────┐
                         │   AlloyDB       │  primary + read pool 2-node
                         │   (hot tier)    │  CMEK, columnar engine
                         │   < 10ms reads  │
                         └─────────────────┘

Servicios horizontales (todos en northamerica-south1):
  • Knowledge Catalog: aspect types LFPDPPP (legal_basis, purpose, retention)
  • DLP: InfoTypes custom MX (CURP, RFC, NSS, INE, CLABE)
  • ARCO service (Cloud Run): derechos de acceso/rectificación/cancelación/oposición
  • Reconciliation service (Cloud Run): valida Oracle vs BQ vs AlloyDB cada hora
  • Breach response service (Cloud Run): notificación Art. 20
  • Audit log archive: bucket inmutable con 5 años de retención
```

## Diferencias vs. arquitectura "standard"

Este stack toma decisiones específicas para optimizar costo, latencia y
cumplimiento. Las más relevantes:

1. **Datastream → BigQuery directo** (no via Pub/Sub + Dataflow). El sink
   nativo de Datastream a BQ con CDC support aplica MERGE automáticamente y
   es ~$1K/mes más barato que pasar por Pub/Sub + Dataflow para analytics.
   Solo el path a AlloyDB requiere Pub/Sub + Dataflow por la latencia.

2. **GCS como landing intermedio** (no Pub/Sub directo). Datastream escribe
   Avro a GCS con file_rotation_interval=15s. Esto da un punto de replay
   barato (los Avros persisten 7 días) y desacopla productor de consumidor.

3. **CMEK desde día 1**. Todas las llaves en `northamerica-south1`. AlloyDB
   no permite agregar CMEK después de creado, por eso es decisión inicial.

4. **ARCO como servicio first-class**. No es un wrapper de queries — es un
   Cloud Run con SLA tracking (20 días Art. 22), tabla `arco_requests` con
   trigger automático, y Cloud Scheduler que alerta antes de vencer.

5. **Audit logs Data Access ON desde el setup**. No están por default en
   GCP. Sin esto no tienes evidencia ante un requerimiento de la
   Secretaría Anticorrupción.

## Estructura del repo

```
cdc-mx/
├── README.md                  ← este archivo
├── docs/
│   ├── ARCHITECTURE.md        ← decisiones técnicas justificadas
│   ├── LFPDPPP_COMPLIANCE.md  ← mapeo artículo → control técnico
│   ├── RUNBOOK.md             ← procedimientos de operación
│   └── COSTS.md               ← desglose de costos
├── terraform/
│   ├── modules/               ← módulos reutilizables
│   │   ├── networking/        ← VPC, subnets, NAT, PSC
│   │   ├── kms/               ← keyring + 4 keys CMEK
│   │   ├── datastream/        ← profiles, stream, GCS landing
│   │   ├── pubsub/            ← topics, subscriptions, DLQ
│   │   ├── alloydb/           ← cluster + read pool con CMEK
│   │   ├── bigquery/          ← datasets, CDC tables
│   │   ├── dataflow/          ← serving job
│   │   ├── catalog/           ← aspect types, glossary, DLP
│   │   ├── arco/              ← Cloud Run + scheduler
│   │   ├── monitoring/        ← alerts, dashboards
│   │   └── audit/             ← log sinks, archive bucket
│   └── envs/prod/             ← composición del entorno
├── oracle/
│   └── setup.sql              ← user CDC + supplemental logging
├── alloydb/
│   ├── 01_schema.sql          ← tablas de dominio
│   ├── 02_compliance.sql      ← consent_log, arco_requests, deletion_log
│   └── 03_purge_jobs.sql      ← retention vía pg_cron
├── bigquery/
│   ├── 01_setup.sql
│   └── 02_views.sql
├── dataflow/serving/          ← Pub/Sub → AlloyDB
├── services/
│   ├── arco/                  ← derechos ARCO
│   └── reconciliation/        ← validación Oracle vs sinks
└── scripts/
    ├── deploy.sh              ← orquestación end-to-end
    ├── verify.sh              ← health check post-deploy
    └── compliance_check.py    ← auditoría LFPDPPP
```

## Quick start

```bash
# 1. Pre-requisitos
#    - GCP project con billing
#    - Oracle 19c+ con archivelog mode
#    - Conectividad VPN/Interconnect entre Oracle y GCP
#    - gcloud, terraform >= 1.5, python >= 3.10, docker

# 2. Configuración inicial
cp terraform/envs/prod/terraform.tfvars.example terraform/envs/prod/terraform.tfvars
# editar con tus valores

# 3. Preparar Oracle (como SYSDBA)
sqlplus sys/PASSWORD@oracle as sysdba @oracle/setup.sql

# 4. Deploy completo (stages 1-5)
./scripts/deploy.sh all

# 5. Esperar 10-30 min a que Datastream haga backfill, luego:
./scripts/deploy.sh 6-catalog   # aplica aspect types y policy tags

# 6. Verificación
./scripts/verify.sh
```

Detalle de cada stage en `docs/RUNBOOK.md`.

## Cumplimiento LFPDPPP

Este stack cubre los controles técnicos exigidos por la ley. Lo que **NO**
cubre (responsabilidad del negocio):

- Aviso de privacidad redactado por abogados
- Contratos con encargados externos no-GCP
- PIA / análisis de riesgo previo
- Designación de Oficial de Protección de Datos
- Programa de capacitación interno
- Procedimiento de respuesta a la Secretaría Anticorrupción

Detalle en `docs/LFPDPPP_COMPLIANCE.md`.
