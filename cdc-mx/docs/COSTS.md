# Estimación de costos mensuales

Estimaciones para el stack completo en `northamerica-south1` con volumen
típico (referencia: 5 TB/mes de CDC, ~1B eventos/mes, ~500 GB en
BigQuery, ~100 GB en AlloyDB).

> Precios en USD, basados en pricing de Google Cloud al momento de redacción.
> Querétaro tiene un premium de 10-15% sobre `us-central1` en algunos
> servicios. Verifica precios actuales antes de presupuestar.

## Resumen

| Categoría                              | Costo mensual aprox |
|----------------------------------------|---------------------|
| Datastream                              | $1,200 - $1,800     |
| AlloyDB (4 vCPU + read pool 2 nodos)   | $1,800 - $2,200     |
| BigQuery (storage + queries)            | $400 - $1,500       |
| Dataflow streaming                      | $500 - $800         |
| Pub/Sub                                 | $150 - $300         |
| Cloud Storage (landing + audit)         | $80 - $150          |
| Cloud Run (ARCO + reconciliation)       | $30 - $80           |
| Cloud KMS                               | $20                 |
| Cloud Logging (audit logs)              | $50 - $200          |
| Networking (VPC, NAT, egress interno)  | $50 - $100          |
| Knowledge Catalog + DLP                 | $100 - $400         |
| Monitoring + alertas                    | $30 - $60           |
| **Total**                               | **$5,800 - $7,200** |

## Datastream

**Pricing:** $0.30 por GB procesado.

- 5 TB/mes × $0.30 = $1,500
- + costos de backfill inicial (one-time, ~$500-1,000)

**Optimización:**
- Excluir tablas que no necesitas (no procesar = no pagar)
- Excluir columnas grandes (LOB, BLOB) si la app no las usa
- Usar `exclude_objects` para skip de tablas de auditoría internas de Oracle

## AlloyDB

**Componentes facturables:**

| Recurso                           | Cantidad             | Costo mensual |
|-----------------------------------|----------------------|---------------|
| Primary instance (4 vCPU, 32 GB)  | 1                    | $700          |
| Read pool nodes (4 vCPU, 32 GB)   | 2                    | $1,400        |
| Storage SSD                       | 100 GB               | $30           |
| Backups (continuous + automated)  | ~150 GB              | $40           |
| Cross-region replication          | 0 (no DR setup)      | $0            |
| Total                             |                      | **~$2,170**   |

**Optimización:**
- CUDs (commitments) de 1-3 años bajan precio 20-40%
- Si el read pool es subutilizado, bajar a 1 nodo (pierde HA en reads)
- Usar `n1` machines en lugar de `n2` si no necesitas SSE4

## BigQuery

**Componentes:**

| Recurso                           | Volumen              | Costo         |
|-----------------------------------|----------------------|---------------|
| Storage (active)                  | 500 GB               | $10           |
| Storage (long-term, >90 días)     | 2 TB                 | $20           |
| Streaming inserts (Datastream CDC)| 1 TB/mes             | $50           |
| Queries (on-demand)               | 1-5 TB scaneados     | $5 - $30      |
| Reservations (slots)              | opcional             | varía         |

Sin reservations, BQ es muy barato en este stack porque las tablas están
particionadas por fecha y clusterizadas por PK. Las queries de la app
escanan partitions específicas.

**Optimización CRÍTICA:**
- `require_partition_filter = true` en tablas grandes
- `max_staleness` para que MERGE no corra cada minuto si no hace falta
- Particionar por `DATE(updated_at)` con expiración automática

## Dataflow

**Streaming engine + n1-standard-4:**

| Recurso                  | Costo            |
|--------------------------|------------------|
| 2-10 workers (autoscale) | $300 - $700      |
| Streaming Engine         | $100 - $200      |
| Shuffle                  | $50 - $100       |
| Storage temp (GCS)       | $5               |

Costo varía mucho con throughput. Un job procesando 1B eventos/mes con
2 workers permanentes y picos a 5 workers cuesta ~$500/mes.

**Optimización:**
- Streaming Engine es no-negociable (sin él, autoscaling es lento)
- Bajar `min_workers` a 1 si toleras cold starts ocasionales
- `n1-standard-4` es el sweet spot; bajar a `-2` reduce throughput
  drásticamente

## Pub/Sub

**Pricing:** $40 por TiB de throughput.

- Eventos típicos: 1B/mes × ~1 KB = ~1 TB
- Costo: $40
- + storage retention (7 días): $20
- + topics + subscriptions: ~$10
- + ordering key: ~$5

Total: ~$75 sin DLQ activos. Si hay backlog en DLQs, el storage sube.

## Cloud Storage

| Bucket                           | Tamaño retenido    | Storage class | Costo   |
|----------------------------------|---------------------|----------------|---------|
| Datastream landing               | 7 días × 100 GB    | Standard       | $5      |
| Audit logs archive               | 5 años × 5 GB/mes  | Coldline       | $30     |
| Dataflow temp                    | <1 día             | Standard       | $5      |
| ARCO exports                     | <30 días           | Standard       | $10     |
| Build artifacts (Artifact Reg.)  | varía              | -              | $20     |

Total: ~$70-150.

## Cloud Run

ARCO + Reconciliation services con tráfico bajo (10-100 requests/día):

- ~$5/mes por servicio en idle
- + invocaciones reales: $0.40 por 1M invocaciones

Total: ~$30/mes.

## Cloud KMS

- Keyring: gratis
- Llaves CMEK: $0.06 por llave por mes × 4 llaves = $0.24
- Operaciones criptográficas: $0.03 por 10K operaciones

Para el volumen típico: ~$15-20/mes.

## Cloud Logging

- Free tier: 50 GB/mes
- Logs estimados: 100-200 GB/mes (incluyendo audit logs Data Access)
- Costo del exceso: $0.50 por GB

Estimado: $25-100/mes.

**Optimización clave:**
- Usar exclusion filters para logs ruidosos no críticos (info de Datastream
  worker startup, etc.)
- Sink a GCS Coldline (mucho más barato que Cloud Logging storage)

## Networking

- VPC: gratis
- Subnets: gratis
- Cloud NAT: $1/hora × 1 = $720/mes ⚠️
- Egress interno (misma región): gratis
- Egress entre regiones GCP: $0.01/GB
- Egress a internet: $0.12/GB

⚠️ **Cloud NAT puede ser costoso.** Considerar:

- Solo usar NAT para Dataflow workers que necesitan PyPI
- Para todo lo demás, Private Google Access (gratis)
- Si el workload de Dataflow no necesita internet (todas las deps en
  imagen Docker), eliminar NAT

Sin NAT, networking baja a $20-50/mes.

## Knowledge Catalog y DLP

- Aspect types: gratis
- Glossary: gratis
- DataScans (DQ y profiling): $0.20 por GB scaneado
- DLP inspect: $1.00 por GB inspeccionado

Profiling diario sobre 500 GB de BQ:
- Sampling 10%: 50 GB × 30 días = 1.5 TB × $0.20 = $300

DLP scan completo mensual:
- 500 GB × $1.00 = $500 (one-time)
- Si lo haces solo cuando hay cambios de schema: $50/mes

Total: $100-400/mes según frecuencia.

## Reducción de costos

Si el budget es ajustado y necesitas reducir, en orden de impacto:

1. **CUDs de AlloyDB** — ahorro $400-700/mes con compromiso de 1 año
2. **Eliminar Cloud NAT** — ahorro $700/mes si los workers no necesitan
   internet
3. **Reducir read pool a 1 nodo** — ahorro $700/mes pero pierde HA
4. **Reducir Dataflow workers a 1 mínimo** — ahorro $200/mes
5. **Bajar BQ partition_expiration** a 90 días en vez de 5 años — ahorro
   $50-200/mes (pero rompe cumplimiento si necesitas evidencia fiscal)
6. **Excluir tablas Oracle no esenciales del CDC** — ahorro proporcional

## Costos NO incluidos

Esta estimación NO cubre:

- Cloud Interconnect / VPN para conexión Oracle (~$200-2,000/mes según
  bandwidth contratado)
- Licencia de Oracle (depende de tu acuerdo con Oracle)
- Costo de personas (operación, on-call, desarrollo)
- Auditorías legales para LFPDPPP
- Subscripciones de monitoring de terceros si las usas (Datadog, etc.)

## Comparación con alternativas

| Stack                                    | Costo aprox  | Trade-off               |
|------------------------------------------|--------------|-------------------------|
| Este stack (managed CDC + AlloyDB)       | $5,800/mes   | Balanceado              |
| Sin AlloyDB (solo BQ, lectura asume lag) | $3,500/mes   | -3s+ lectura            |
| Con Debezium+Kafka self-managed          | $7,500/mes   | Sub-segundo, complejo   |
| Con GoldenGate                           | $9,000+/mes  | Latencia ~100ms, soporte|
| Cloud SQL en lugar de AlloyDB            | $4,800/mes   | Lecturas más lentas     |
