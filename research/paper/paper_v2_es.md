---
title: "Dazzle: Una base de datos embebida para agentes LLM on-device"
author: "Ivan Aliaga"
date: "Abril 2026"
mainfont: "Times New Roman"
monofont: "Menlo"
fontsize: 11pt
geometry: margin=0.75in
linkcolor: blue
abstract: |
  Las aplicaciones móviles que embeben un agente con un modelo de
  lenguaje hoy necesitan una capa de estado persistente entre las
  llamadas de inferencia: ventanas de sensores, agregados
  materializados, conteos aproximados, índices vectoriales sobre
  contexto reciente. Las bases de datos embebidas disponibles en la
  plataforma (SQLite, RocksDB, LMDB, ObjectBox) ofrecen entre dos y
  cuatro primitivas de estructura de datos cada una, así que cada
  construcción de orden superior (bounded streams, TTL por campo,
  HyperLogLog, búsqueda vectorial HNSW) termina re-implementada en
  código de aplicación, sobre esas primitivas, por cada equipo que
  la necesita.

  Presentamos **Dazzle**, un fork de Valkey (la versión Linux
  Foundation de Redis) cuyo servidor corre *dentro* del proceso de
  aplicaciones Android e iOS en lugar de como demonio sobre TCP
  loopback. El fork expone diez primitivas nativas de estructura de
  datos, incluyendo búsqueda vectorial HNSW, contra $\leq 4$ en
  cualquier competidor embebido que medimos en las mismas
  plataformas; las expone a través de un SDK móvil tipado en Maven
  Central, pub.dev, npm y Swift Package Manager.

  Caracterizamos el envelope de latencia para doce backends en dos
  dispositivos físicos (Moto G35 5G, iPhone 12 Pro). El retrieval en
  estado estable sobre el path de agregados materializados aterriza
  en 50 µs en el Moto G35 5G y 7.24 µs en el iPhone 12 Pro; la
  búsqueda vectorial HNSW se mantiene en sub-milisegundo a recall
  $\geq 0.95$ a lo largo de la grilla de 9 configuraciones que
  medimos. A 50 µs frente a un turno de inferencia LLM on-device de
  $\sim 2.84$ s, el costo de retrieval representa el **0.00176 %**
  de la llamada de inferencia: por debajo del piso de ruido del
  bucle end-to-end. El eje de decisión para un backend de agente
  on-device es por tanto la **superficie primitiva y la ergonomía
  del desarrollador**, no los deltas de microbenchmark. Reportamos
  los números absolutos por motor en microsegundos de todas formas,
  porque los mismos motores también sirven cargas no-LLM
  (analítica, sincronización, indexación) donde los microsegundos sí
  importan.

  Una ablación 2×2 end-to-end sobre 200 queries de Natural Questions
  en el Moto G35 5G muestra que la primitiva de retrieval es lo que
  impulsa la accuracy factual a esta escala. Qwen 2.5 0.5B con
  Dazzle RAG alcanza 0.630 `EM_contains` contra 0.105 sin retrieval
  (6.0×); Qwen 2.5 1.5B con RAG alcanza 0.735 contra 0.110 sin
  retrieval (6.7×). Un modelo de 380 MB con retrieval supera a un
  modelo de 940 MB (3× más grande) sin retrieval en cada métrica
  factual, end-to-end en un teléfono Android de \$150. El cuello de
  botella no es el tamaño del modelo, ni el SoC, ni el costo en
  microsegundos del retrieval; es si el backend permite que el bucle
  del agente alcance un índice vectorial siquiera.
---

> **Nota sobre esta versión.** Esta es una traducción técnica al
> español del paper en inglés `paper_v2_en.md`, mantenida en paralelo
> al original. La fuente de verdad para arXiv y para todas las
> tablas / claims experimentales sigue siendo la versión en inglés.
> Se preservan en inglés los términos técnicos reservados de la
> literatura (LLM, RAG, HNSW, snapshot cache, key-value, sorted set,
> HyperLogLog, NEON SDOT, SIMD, in-process, write-through, backend,
> daemon, thread, lock, atomicity, prefill, decode, embedding,
> retrieval, fork, harness, benchmark, footprint, ingest,
> wrapper, etc.) tal como aparecen en el dominio.

# 1. Introducción

Los modelos de lenguaje cuantizados de menos de 3 GB hoy corren a
tasas interactivas en hardware ARM64 de clase smartphone: Gemma 2
[@gemma2] y Gemma 4 [@gemma4], Phi-3 mini [@phi3], la serie Llama 3
[@llama3] (incluyendo Llama 3.2 1B y 3B), MobileLLM [@mobilellm], y
la serie Qwen 2.5 [@qwen25] que usamos en §5.9. El stack de runtime
— `llama.cpp` [@llamacpp] con su formato de pesos cuantizados GGUF
[@gguf], LiteRT-LM [@litertlm], MLC-LLM [@mlcllm], ExecuTorch
[@executorch] — está maduro y alcanza latencia sub-segundo por
token decodificado en handsets de \$150.

La **capa de estado** que un agente necesita no ha madurado al
mismo ritmo. Por capa de estado nos referimos al lugar donde el
agente guarda lo que ha visto entre llamadas de inferencia,
coordina entre turnos, y sobrevive reinicios de proceso.

Considere un agente de monitoreo IoT móvil: recolecta lecturas de
temperatura, humedad, presión y batería a intervalos; un LLM
procesa lotes en checkpoints y produce reportes de síntesis. Entre
checkpoints el agente necesita (1) un bounded buffer ordenado en el
tiempo sobre las lecturas más recientes, (2) agregados en running
(min/max/avg/count) sin re-escanear historia, (3) conteo
probabilístico para señales de anomalía y cardinalidad, y (4) TTL
por campo para mantener el bloque de contexto dentro del
presupuesto del prompt. Cada requerimiento mapea limpiamente a una
estructura de datos específica: bounded streams, sorted sets y
hashes, HyperLogLog, TTL sobre hash fields. Ninguna es exótica.
Ninguna es problema de investigación.

Ningún backend en la plataforma las ofrece como primitivas nativas.
En Android e iOS las opciones embebidas dominantes — SQLite
[@sqlite], RocksDB [@rocksdb] (un descendiente LSM-tree de LevelDB
[@leveldb]), LMDB [@lmdb], ObjectBox [@objectbox4], y el peer
embebido analítico DuckDB [@duckdb] — exponen entre dos y cuatro
estructuras de datos en total: filas, key-value pairs, blob stores,
ocasionalmente un índice vectorial. Cada construcción de orden
superior (bounded streams, agregados materializados, conteos
aproximados, semántica TTL, similarity search) tiene que ser
re-implementada en código de aplicación sobre esas primitivas, por
cada equipo que las necesita. El código resultante es frágil bajo
acceso concurrente. Las garantías de atomicidad que vienen gratis
con un servidor in-process maduro se pierden silenciosamente. La
misma media docena de bugs se redescubre app tras app.

La aritmética de latencia libera al argumento de la habitual
carrera de microbenchmarks. Incluso el backend embebido más lento
en nuestra evaluación — SQLite a aproximadamente 3 ms de retrieval
en N = 20 000 bajo carga concurrente en un handset Android de
\$150 — está tres órdenes de magnitud por debajo de un solo turno
de inferencia LLM on-device (1–3 segundos para un modelo de 1–3
miles de millones de parámetros). El retrieval en microsegundos no
es lo que mueve la aguja del producto. Lo que la mueve es qué
primitivas expone el backend, qué tan ergonómicas son de invocar, y
cuánto código pegamento escribe el autor del agente antes de que la
capa de estado se comporte.

El eje correcto de comparación para backends de agentes on-device,
argumentamos, es **superficie primitiva y ergonomía del
desarrollador**, no throughput crudo de microbenchmark. Cuatro
piezas de evidencia respaldan esa posición: (a) el envelope de
latencia de Dazzle se ubica cómodamente dentro del piso de ruido
LLM en cada configuración que probamos; (b) primitiva-por-primitiva
Dazzle expone **diez primitivas nativas contra $\leq 4$ en
cualquier competidor embebido en las mismas plataformas**; (c) una
comparación en líneas de código para la misma capa de estado del
agente; y (d) una demostración end-to-end de que las primitivas que
Dazzle expone habilitan patrones cualitativamente nuevos —
small-model + on-device retrieval-augmented generation [@lewisrag;
@karpukhindpr] — que no son alcanzables cuando la única primitiva
disponible es un store key-value plano o de filas.

**Contribuciones.**

1. **Primer port in-process de Valkey a procesos de aplicación
   Android e iOS**: un transporte self-pipe, un snapshot cache con
   write-through, y un SPSC ring buffer en Android reemplazan el
   TCP loopback de Valkey preservando la superficie completa de
   primitivas y el scripting Lua.
2. **Una contribución de ingeniería medida más dos capas de
   future-proofing** (§3, §5.4). El snapshot cache write-through es
   la única capa que mueve throughput sobre la carga
   Write-Heavy / Read-Light medida — la ablación factorial 2³ de
   §5.4 muestra que el worker pool paralelo y el path de dispatch
   por hash-bucket son no-ops sobre esta carga (dentro del ruido
   run-to-run) porque el snapshot cache ya absorbe la contención
   que ellos fueron diseñados para remover. Mantenemos esas dos
   capas en la arquitectura como headroom de keyspace-scaling: bajo
   benchmarks no corridos en este paper (keyspaces mucho más
   grandes, múltiples threads escritores, fan-in desde varias
   producer queues) esperamos que ganen su costo de vuelta, y los
   números de §5.4 describen las condiciones bajo las que no lo
   hacen. El auto-mirror post-EVAL que mantiene visible al cache el
   estado mutado por Lua, y el transporte in-process en sí, son las
   dos contribuciones de ingeniería adicionales de interés
   independiente documentadas en §3.
3. **Caracterización del envelope de latencia** sobre doce
   backends, con N de 200 a 20 000, en un handset Android de
   presupuesto (Moto G35 5G, Unisoc T760) y un iPhone 12 Pro
   físico — paridad completa de bench-coverage (cada backend corre
   en ambas plataformas; iOS retiene el transporte self-pipe de
   Phase-0 — ver §6.3 — y las optimizaciones SPSC ring buffer /
   `io_uring` son Android-only), incluyendo el port nativo iOS de
   ObjectBox 5.3 cableado en esta revisión (entidades, bindings
   generados con Sourcery, y una test suite XCTest corrible en
   simulador en
   `experiment/storage/ios/Tests/ObjectBoxTests.swift`).
4. **Comparación de superficie primitiva y complejidad de
   desarrollo** contra cinco alternativas embebidas (SQLite, LMDB,
   RocksDB, ObjectBox, InMemory) más una referencia de
   Valkey-sobre-TCP: diez primitivas nativas contra $\leq 4$, con
   medidas concretas de LOC para la misma capa de estado del
   agente (§5.6).
5. **Demostración end-to-end** vía una ablación 2×2 RAG sobre 200
   queries NQ (§5.9, Tabla 15). Agregar la primitiva vectorial de
   Dazzle eleva `EM_contains` 6.0× sobre Qwen 2.5 0.5B (0.105 →
   0.630) y 6.7× sobre Qwen 2.5 1.5B (0.110 → 0.735); la celda de
   small-model-with-retrieval supera a la de
   large-model-without-retrieval en cada métrica factual. El
   resultado habla de qué se vuelve implementable cuando la
   primitiva correcta está presente, no de un delta en
   microsegundos sobre un competidor.
6. **Distribución pública del SDK** de `dazzle-sdk` 1.0.0-beta.4
   sobre cuatro registries estándar (Maven Central, pub.dev, npm,
   Swift Package Manager), con cinco adaptadores LLM detrás de una
   interfaz `LLMClient` común (Apéndice A). Apache-2.0 (Dazzle) /
   BSD-3-Clause (porciones derivadas de Valkey).

# 2. Contexto y motivación

## 2.1 Requerimientos de estado para un agente LLM on-device

Un LLM-como-agente difiere de la inferencia de un solo turno en que
debe:

- Mantener una ventana de observación bounded (buffer circular con
  desalojo automático).
- Trackear running aggregates (min/max/avg sin re-scan O(N)).
- Contar aproximadamente eventos distintos (HyperLogLog en 12 KB
  con $\sim$0.8 % error relativo [@hyperloglog] vs O(N) exacto).
- Aplicar TTL por campo a observaciones obsoletas (expiración
  automática sin un cron en la app).
- Señalizar entre componentes (Pub/Sub sin polling).

Estas primitivas existen desde hace una década en Redis/Valkey. Lo
nuevo es embeberlas **dentro del proceso de la app móvil** para que
el salto de red entre agente y store desaparezca.

## 2.2 Primitivas nativas por backend

**Tabla 1 — Disponibilidad por primitiva por backend embebido.**
Cada celda registra *cómo* se alcanza la primitiva, no solamente
*si* es alcanzable. **N** = llamada nativa de API tipada que el
motor mismo provee. **E** = extensión oficial provista por el
proyecto upstream (e.g., R*Tree de SQLite, en la amalgamation desde
2008). **A** = re-implementación a nivel de aplicación — el
desarrollador escribe código pegamento sobre primitivas más bajas
en el motor. **T** = extensión de tercero distribuida separadamente
del motor. La fila "Total Native" cuenta solo **N**; **E**, **A** y
**T** significan que la primitiva es *alcanzable* pero con costo de
ingeniería distinto, capturado cuantitativamente por el diferencial
de LOC en la Tabla 9 y discutido explícitamente en §6.3.

| Primitiva                       | Dazzle | SQLite | RocksDB | ObjectBox | LMDB |
|---------------------------------|:------:|:------:|:-------:|:---------:|:----:|
| Bounded stream con MAXLEN       |   N    |   A    |    A    |     A     |  A   |
| Sorted sets con range query     |   N    |   A¹   |    A    |     N     |  A   |
| Atomic float increment          |   N    |   A²   |    A    |     A     |  A   |
| TTL por campo                   |   N    |   A    |    A    |     A     |  A   |
| HyperLogLog                     |   N    |   A    |    A    |     A     |  A   |
| Geo indexing                    |   N    |   E³   |    A    |     A     |  A   |
| Pub/Sub                         |   N    |   A    |    A    |     N⁴    |  A   |
| Server-side scripting (Lua)     |   N    |   A    |    A    |     A     |  A   |
| Vector search (HNSW)            |   N    |   T⁵   |    A    |     N     |  A   |
| Iteración basada en cursor      |   N    |   N    |    N    |     N     |  N   |
| **Total Native (N)**            | **10** | **1**  | **1**   |  **4**    | **1**|

¹ Implementable vía `ORDER BY … WHERE … BETWEEN` en SQL de la app.
² Implementable vía `UPDATE … SET v = v + ?` dentro de una
transacción. ³ R*Tree es una extensión oficial de SQLite incluida
dentro de la amalgamation desde 2008. ⁴ El `DataSubscription` de
ObjectBox es una API de 1-call tipada para consumidores de
notificación de cambios; lo contamos como un equivalente nativo de
pub/sub para el caso de uso del bucle del agente (un solo
consumidor suscrito a un stream tipado de cambios), aun cuando es
observer-pattern en lugar de topic-routed. ⁵ SQLite no tiene una
primitiva vectorial nativa ni oficial; el vector search lo proveen
solo extensiones de tercero (`sqliteai/sqlite-vector` comercial,
`asg017/sqlite-vec` open-source), que benchmarkearemos
separadamente en §5.8 como peers comerciales en lugar de como
feature nativo de SQLite.

El conteo del headline (10 vs $\leq 4$ nativas) mide **cuántas
primitivas el autor del agente puede alcanzar con una sola llamada
tipada de librería** — el eje de "superficie primitiva" de la
tesis Dazzle. Las primitivas marcadas **E**, **A** o **T** en
backends no-Dazzle son *implementables*; la pregunta es el costo de
ingeniería, que medimos directamente en §5.6 (Tabla 9: 175 LOC
Android / 186 LOC iOS para Dazzle vs 200–290 LOC para los
equivalentes basados en SQLite). Un revisor leyendo la Tabla 1 como
"primitivas que existen en cualquier parte del ecosistema de este
motor" llega a un gap mucho más pequeño. Esa es una pregunta
distinta (y más débil) que la que la Tabla 1 está estructurada para
responder, y §6.3 Limitaciones deja la elección del eje explícita.
Los experimentos de performance que siguen respaldan el argumento
cuantitativo, incluyendo el benchmark vectorial head-to-head contra
ObjectBox 4.x y SQLiteAI sqlite-vector 0.9.95 en §5.8.

## 2.3 Por qué embeber Valkey, y por qué como fork

Valkey fue diseñado para servidores Linux: daemon long-lived, TCP
loopback, asunciones POSIX de GNU libc, shutdown vía `exit()`.
Ninguna sobrevive un port a un proceso de app móvil. Dazzle aplica
tres cambios como overlay del fork. El primero es **portabilidad**:
shims para Bionic libc de Android y para el SDK de Apple. El
segundo es **lifecycle**: el servidor no puede matar a su proceso
host. El tercero es **transporte in-process**: el TCP loopback es
puro overhead cuando cliente y servidor comparten el address space.

El upstream de Valkey no se vendoriza. Lo descargamos en un tag
fijo y le aplicamos tres diffs (~180 líneas en total) antes de
compilar. Publicar solo los diffs preserva la licencia BSD-3-Clause
de Valkey; el código original de Dazzle (en `core/` y `sdk/`) es
Apache-2.0.

# 3. El sistema Dazzle

## 3.1 Arquitectura

Dazzle se organiza en tres capas:

- **`core/`** (Apache-2.0). Transporte in-process
  (`core/transport/dazzle_transport.c`) + snapshot cache + worker
  pool (Android). C puro, compilado con el Valkey patcheado.
- **`versions/<ver>/patches/`** (diffs de build-time). Tres
  patches: Android (shims de Bionic), iOS (ajustes para el SDK de
  Apple + un `malloc_zone_t` custom para reportar RSS aislado), y
  un hook de 14 líneas en `server.c` que inserta
  `dazzle_direct_init()` después de `InitServerLast()`.
- **`sdk/android/`, `sdk/ios/`** (Apache-2.0). Bridges JNI + Kotlin
  (AAR) y bridges C + Swift (XCFramework).

## 3.2 Transport path

El event loop de Valkey corre sobre un `pthread` dedicado. El
thread de la aplicación se comunica vía:

- **Pipe in-process.** El thread de la app hace `write()` de un
  pointer de 8 bytes a un `DirectRequest`, muy por debajo de
  `PIPE_BUF` ($\geq$ 512 bytes por POSIX, 4 096 en Linux), así que
  el kernel garantiza entrega atómica sin lock del lado escritor.
  El event loop despierta en `read()`, ejecuta `call()` con un
  cliente fake, y señaliza el `condvar` con la respuesta RESP.
- **Snapshot cache write-through.** Cada comando mutador que cruza
  el pipe actualiza un cache in-process bajo rwlock antes de
  liberar al caller. Las lecturas subsiguientes adquieren el rdlock
  y retornan valores directamente, sin wake-up del event loop. El
  pipe es síncrono, así que para cuando una lectura se dispara el
  cache ya refleja cada escritura previa: **cero staleness por
  construcción**.
- **Worker pool (Android).** 2–4 threads adicionales absorben
  lecturas concurrentes bajo rwlocks striped por slot cuando el
  flag de entorno `DAZZLE_PARALLEL_READS=1` está activo.

## 3.3 Auto-mirror post-EVAL

Los scripts Lua (`EVALSHA`) ejecutan sus escrituras internas a
través del `call()` de Valkey, que no dispara el hook del
snapshot-mirror. Sin trabajo adicional, los backends que escriben
campos dentro de un script Lua y los leen después pagarían el costo
pipe-HMGET en cada lectura. Dazzle hidrata el cache automáticamente
después de cada `EVAL`: itera sobre los KEYS declarados del script,
re-lee cada hash a través de la API de kvstore, y hace upsert de
sus campos al bucket correspondiente. Un backend que escribe 8
campos dentro de un Lua EVALSHA los ve reflejados en el snapshot en
la siguiente lectura, sin trabajo adicional en el SDK.

# 4. Diseño experimental

## 4.1 Carga de trabajo

Agente sintético de monitoreo IoT: 200 lecturas con cinco campos
(temperatura, humedad, presión, batería, vibración), 11 anomalías
inyectadas, 10 checkpoints de inferencia espaciados uniformemente.
Dos condiciones: **Stateless** (el modelo recibe solo las últimas
20 lecturas) y **Augmented** (las 20 lecturas + un bloque de
contexto materializado con agregados sobre la ventana completa).

## 4.2 Backends

Cinco alternativas embebidas (SQLite, LMDB, ObjectBox, RocksDB,
InMemory) más una referencia Valkey-sobre-RESP-TCP (el servidor
Valkey 8 sin modificaciones con loopback localhost, incluido como
baseline de "transport overhead") y siete variantes de Dazzle
exponiendo distintos paths de primitivas: básico, Lua, Pipeline,
HFE, HLL, **Precompute** (agregados materializados) y **Vector**
(búsqueda vectorial HNSW). Doce backends en total por dispositivo,
con **paridad completa de bench-coverage** sobre los sweeps
storage-only y vector-bench en esta revisión (cada backend corre en
ambas plataformas; el port iOS de ObjectBox 5.3 aterriza en §5.6, y
el path Dazzle-Vector corre en ambas plataformas vía el preset
unificado `paper384_scale`).

## 4.3 Dispositivos

Mediciones físicas en dos dispositivos:

- **Moto G35 5G** (Unisoc T760, 8×ARM @ 2.0/2.2 GHz, 4 GB LPDDR4X,
  Android 14). El handset Android de presupuesto / referencia.
- **iPhone 12 Pro** (Apple A14 Bionic, 6 GB LPDDR4X, iOS 26.3). El
  punto de validación cross-platform.

Los runs storage-only se hacen sobre ambos dispositivos. Los runs
vector-bench se hacen sobre el Moto G35 5G y, en esta revisión,
también sobre el iPhone 12 Pro vía el preset `paper384_scale`. El
RAG end-to-end de §5.9 corre sobre el Moto G35 5G; la validación
cross-platform end-to-end queda como trabajo futuro en §6.3.

## 4.4 Métricas

- **Ingest**: microsegundos por lectura (per-reading ingest µs).
- **Retrieval**: microsegundos promedio sobre la ventana de
  retrieval-sample, p50 y p95.
- **Footprint**: bytes en disco después de los 200 ingests
  (`stat.st_blocks × 512`, equivale a `du -k`).
- **Vector**: p50 / p95 / p99 search latency sobre 100 queries por
  celda en estado estable warm; recall@k contra una verdad
  brute-force SQLite.
- **RAG E2E**: `EM_short`, `EM_contains`, `F1_short`, `F1_passage`
  por query, agregados sobre 200 queries de NQ.

Bootstrap percentile-method ($B = 10\,000$, seed = 42)
[@efronbootstrap; @davisonhinkley] sobre las arrays per-query para
los CIs reportados en las tablas. Los scripts de re-derivación
están en `research/scripts/bootstrap_*_lats.py`.
