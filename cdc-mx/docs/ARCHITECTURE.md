# Architecture Decision Record

Este documento explica las decisiones de diseño y por qué se eligió cada
camino. Si algo se ve "raro" o no-óptimo, probablemente hay una razón
documentada aquí.

## ADR-001: Región única `northamerica-south1`

**Decisión:** todo el stack vive en Querétaro (`northamerica-south1`).

**Contexto:** la NLFPDPPP no exige residencia forzosa pero la Secretaría
Anticorrupción puede requerir acceso, y residencia local reduce fricción
regulatoria. El cliente requirió residencia estricta en México.

**Trade-offs:**

- Pros: residencia clara, latencia baja para usuarios mexicanos, alineado
  con expectativas regulatorias.
- Contras: región más nueva (GA 2024), algunas features pueden tardar más
  en llegar (ej. ciertos machine types específicos para Dataflow). Costos
  ligeramente superiores a `us-central1` (~10-15%).

**Servicios verificados disponibles:**
Datastream, AlloyDB, Cloud Run, Dataflow, BigQuery, Pub/Sub, Cloud KMS,
Cloud Storage, Compute Engine (3 zonas), Secret Manager, Cloud Scheduler.

**Riesgo aceptado:** Knowledge Catalog tiene componentes globales
(catalogación de PII a nivel taxonomía). El metadato del catálogo no es
data personal sino metadatos sobre data personal, lo cual no cambia la
clasificación regulatoria de los datos en sí.

## ADR-002: Datastream → BigQuery directo (no via Pub/Sub)

**Decisión:** para el sink analítico, usar el sink nativo de Datastream a
BigQuery con CDC support. **No** pasar por Pub/Sub + Dataflow.

**Contexto:** la primera versión del diseño usaba un único path
`Datastream → Pub/Sub → Dataflow → {BQ, AlloyDB}` para tener un único
punto de fan-out. Pero el costo era ~$2K/mes solo en Dataflow para
analytics que no requieren baja latencia.

**Trade-offs:**

- Pros: ~$1.5K/mes de ahorro, menos componentes que mantener, MERGE
  automático aplicado por el sink, esquema-evolution gestionado.
- Contras: lag mayor (5-30s vs 1-3s del path con Pub/Sub). Aceptable para
  analítica.
- Pros adicional para LFPDPPP: menos componentes en el path = menor
  superficie de ataque y menos auditoría a documentar.

**Alternativa rechazada:** BigQuery Subscription de Pub/Sub. Funciona pero
no aplica MERGE automático — habría que escribir vistas con `ROW_NUMBER()`
sobre la PK para deduplicar, lo cual encarece queries.

## ADR-003: GCS como landing intermedio para path AlloyDB

**Decisión:** Datastream escribe Avro a GCS, GCS dispara notificación a
Pub/Sub, Dataflow consume de Pub/Sub. **No** Datastream → Pub/Sub directo.

**Contexto:** Datastream soporta Pub/Sub como destino directo en preview,
pero documentación indica que es preview y schemas son menos estables.

**Trade-offs:**

- Pros: GA y battle-tested, Avros persistentes 7 días dan replay barato
  ante incidentes, archivos pequeños (5MB con file_rotation_interval=15s)
  reducen latencia.
- Contras: hop adicional GCS → Pub/Sub agrega ~500ms de latencia.
- Net: 1-3s sigue dentro de presupuesto.

**Configuración crítica:**
```
file_rotation_mb = 5
file_rotation_interval = 15s
```
Default de Datastream es 50MB / 60s, lo cual da latencia de ~60s. La
optimización aquí es decisiva para baja latencia.

## ADR-004: AlloyDB en lugar de Bigtable o Cloud SQL

**Decisión:** AlloyDB como hot tier.

**Trade-offs:**

| Opción     | Pros                                       | Contras                                   |
|------------|--------------------------------------------|-------------------------------------------|
| Bigtable   | Latencia <5ms, escala lineal               | Sin SQL, sin joins, requiere rediseño     |
| Cloud SQL  | Más barato, simple                         | No tan rápido, sin columnar engine        |
| AlloyDB    | PostgreSQL completo, columnar, single-digit ms reads | Más caro que Cloud SQL, regional |

**Razón:** la app viene de Oracle relacional. AlloyDB es PostgreSQL
completo con joins, FK, índices secundarios. Bigtable forzaría rediseño
completo de la capa de acceso a datos. Cloud SQL no tiene columnar engine
ni el mismo nivel de read replicas.

**Configuración para latencia:**

- `random_page_cost = 1.1` (planner agresivo con índices)
- `effective_io_concurrency = 200`
- `shared_buffers` = 25% RAM (default AlloyDB)
- Read pool con 2 nodos (HA + absorción de lecturas)
- Connection pool por worker, no por request (PgBouncer en transaction mode)

## ADR-005: CMEK obligatorio desde el inicio

**Decisión:** todos los stores con datos personales usan CMEK con keys en
Cloud KMS de `northamerica-south1`.

**Contexto:** Art. 19 LFPDPPP exige "medidas de seguridad técnicas
adecuadas". Sin CMEK, las llaves las controla Google y la organización no
puede demostrar control efectivo.

**Restricción operacional:** AlloyDB **no permite** agregar CMEK a un
cluster existente. Si se omite al inicio, la migración requiere
backup/restore con downtime. Por eso es decisión inicial, no posterior.

**Llaves separadas por servicio:**

- `bigquery-cmek` — analítica
- `alloydb-cmek` — hot tier
- `storage-cmek` — GCS landing y audit archive
- `pubsub-cmek` — eventos en tránsito

Razón de separar: revocar la key de un servicio no afecta los otros. Útil
ante un incidente localizado.

**Rotación:** 90 días automática.

## ADR-006: Pub/Sub con ordering key = primary key

**Decisión:** todas las publicaciones a Pub/Sub usan `ordering_key` igual
a la primary key de la tabla origen.

**Contexto:** sin ordering key, eventos del mismo registro pueden llegar
desordenados al consumer. Esto causa que un UPDATE viejo sobrescriba a un
UPDATE nuevo, dejando AlloyDB inconsistente con Oracle.

**Implementación:** el job de Dataflow en `dataflow/serving/main.py`
configura ordering_key explícitamente. Pub/Sub respeta orden dentro de
una misma key, no globalmente.

**Trade-off:** ordering reduce throughput máximo por subscription (~2K
msgs/s por ordering key). Para tablas con muy alta carga de cambios sobre
pocas keys, esto puede ser bottleneck. Mitigación: sharding lógico de la
ordering key (ej. `pk:hash(pk) % 16`).

## ADR-007: Idempotencia con SCN guard

**Decisión:** los upserts a AlloyDB incluyen `WHERE existing.cdc_scn <
incoming.cdc_scn` para no aplicar mensajes duplicados o desordenados.

**Contexto:** Pub/Sub garantiza at-least-once por default (exactly-once en
preview pero con costos). At-least-once significa que el mismo mensaje
puede entregarse 2-3 veces.

**Implementación:** función `upsert_customer()` en AlloyDB con guard
explícito. El SCN (System Change Number) de Oracle es monotónicamente
creciente y único por commit, ideal para este uso.

## ADR-008: Servicio ARCO independiente, no funciones inline

**Decisión:** Cloud Run dedicado para los cuatro derechos ARCO (Acceso,
Rectificación, Cancelación, Oposición), no funciones SQL ni endpoints en
otra app.

**Razones:**

1. SLA tracking automatizado (Cloud Scheduler valida el plazo de 20 días
   cada 4h y alerta antes de vencer).
2. Auditoría centralizada: cada solicitud queda en `arco_requests` con
   timestamp de submission, deadline, resolución y ejecución.
3. Identidad del solicitante separada del operador del sistema.
4. Lógica compleja: cancelación con bloqueo cuando hay obligación legal
   de retener (CFF Art. 30: 5 años de registros contables).

## ADR-009: Audit logs Data Access habilitados a nivel proyecto

**Decisión:** `google_project_iam_audit_config` con `DATA_READ`,
`DATA_WRITE`, `ADMin_READ` para `allServices`.

**Contexto:** Data Access logs son la única evidencia ante un
requerimiento de la Secretaría sobre quién accedió a datos personales.
**No están habilitados por default.**

**Costo:** ~$0.50 por GB de logs ingeridos. Para el volumen esperado
(~10-50 GB/mes), costo es trivial vs. la consecuencia de no tener
evidencia.

**Sink dedicado:** logs van a un bucket GCS con retention policy de 5
años (alineado con CFF para evidencia fiscal). Bucket con CMEK y
versioning. Considerar `is_locked = true` cuando esté validado.

## ADR-010: Reconciliación cada hora, no continua

**Decisión:** Cloud Run service ejecutado por Cloud Scheduler cada hora,
no streaming.

**Razones:**

1. Reconciliación continua es costosa y ruidosa.
2. Lag de 1h es aceptable para detectar divergencias en la práctica.
3. Permite usar `COUNT(*)` y `MAX(updated_at)` en lugar de hashes
   continuos, mucho más barato.

**Estrategia:**

- COUNT(*) por tabla en Oracle, BQ, AlloyDB.
- MAX(updated_at) por tabla.
- Hash MD5 de PKs sampleadas (1 de cada 1000) si counts difieren.
- Si divergencia > 0.1%, log con severity ERROR (dispara alerta).

## ADR-011: BigQuery Subscription rechazado para CDC

**Decisión:** **no** usar BigQuery Subscription como mecanismo principal
para mover datos a BQ.

**Contexto inicial:** considerada como simplificación.

**Razón de rechazo:** BQ Subscription escribe append-only, no aplica
MERGE. Para CDC necesitas reconstruir el estado actual con vistas que
hacen `ROW_NUMBER() OVER (PARTITION BY pk ORDER BY scn DESC)`. Esto es:

- Más lento en queries analíticas
- Más caro (las vistas escanean toda la historia)
- Más complejo de operar

Datastream con CDC support aplica MERGE automáticamente. Decisión clara.

## ADR-012: Sin tooling DBT/Dataform para transformaciones

**Decisión:** las tablas en BigQuery son CDC-managed (las gestiona
Datastream). No hay capa de transformación adicional en este stack.

**Contexto:** muchos proyectos meten DBT/Dataform encima de BQ para
modelado dimensional. Aquí esa capa **no es parte del stack** porque:

1. Es una decisión de modelado, no de plataforma.
2. Mezcla concerns (CDC vs. modelado).
3. Cada equipo de analytics tiene su preferencia.

Las tablas finales (analytics.customers, analytics.orders) son la
"capa cruda" lista para que cualquier herramienta de modelado consuma.

## Anti-patrones evitados

- **No reusar la misma key CMEK para todos los servicios.** Si tienes
  una sola key y la revocas por incidente, todo el stack se cae.
- **No omitir ordering key en Pub/Sub.** Causa inconsistencia silenciosa.
- **No usar default Google-managed encryption.** Para LFPDPPP debe ser
  CMEK.
- **No omitir audit logs Data Access.** Sin esto no hay evidencia
  forense.
- **No mezclar serving y analytics en un mismo job de Dataflow.** Las
  cargas tienen requisitos opuestos (latencia vs throughput).
- **No usar Cloud SQL si el origen es Oracle con queries relacionales
  complejas.** AlloyDB es la elección correcta.
