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
  reproduce sobre dos SoCs Android físicos (Moto G35 5G — Unisoc
  T760 ARMv8.2 A76; Moto G30 — Qualcomm SD662 ARMv8.0 A73) y
  muestra que la primitiva de retrieval es lo que impulsa la
  accuracy factual a esta escala. Qwen 2.5 0.5B con Dazzle RAG
  alcanza 0.630 `EM_contains` contra 0.105 sin retrieval (6.0×);
  Qwen 2.5 1.5B con RAG alcanza 0.735 contra 0.110 sin retrieval
  (6.7×). Tres de las cuatro celdas de la 2×2 son bit-idénticas
  entre los dos chips (Q4_K_M + greedy decoding + retrieval set
  idéntico determinizan el token stream); el patrón de
  significancia paired-ratio es invariante. Un modelo de 380 MB
  con retrieval supera a un modelo de 940 MB (3× más grande) sin
  retrieval en cada métrica factual, end-to-end en un teléfono
  Android de \$150. El cuello de botella no es el tamaño del
  modelo, ni el SoC, ni el costo en microsegundos del retrieval;
  es si el backend permite que el bucle del agente alcance un
  índice vectorial siquiera.
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
  con $\sim 0.8$ % error relativo [@hyperloglog] vs O(N) exacto).
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
RAG end-to-end de §5.9 cubre dos SoCs Android físicos (Moto G35
5G + Moto G30; §5.9.5) y aún no iPhone 12 Pro.

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

# 5. Evaluación

## 5.1 La memoria externa habilita la síntesis

**Tabla 2 — Accuracy de síntesis factual sobre estadísticas
globales (checkpoint final).**

| Condición                    | Total de lecturas        | Conteo de anomalías | Temperatura media       | Score   |
|------------------------------|:------------------------:|:-------------------:|:-----------------------:|:-------:|
| Stateless                    | -- (confabula ~50)       | -- (confabula 2–3)  | -- (confabula ~21 °C)   | **0/3** |
| Augmented (cualquier backend)| Y (200)                  | Y (11)              | Y (22.4 °C)             | **3/3** |

Este es el hallazgo empírico central del paper. Sin memoria externa
el modelo no tiene acceso a datos fuera de su ventana de contexto
actual (las últimas 20 lecturas), así que las "estadísticas
globales" que produce son confabulaciones. Con un bloque de
contexto materializado, el modelo lee los valores exactos y los
reproduce. El backend específico es irrelevante para este hallazgo.
Lo que importa es que la memoria exista y que el contexto sea
preciso.

La implicación para el diseño de agentes es directa: **la capa de
memoria externa es infraestructura obligatoria para cualquier tarea
que razone sobre estado acumulado**, no una optimización opcional.
La elección del backend después se reduce a performance, superficie
primitiva, y ergonomía.

## 5.2 Caracterización del envelope de latencia

Esta sección establece el envelope de latencia en el que un backend
de agente on-device debe operar. No es una declaración de ganador
de microbenchmark. Medimos cada backend en dos regímenes: un sweep
storage-only en N = 200 lecturas en ambos dispositivos físicos
(Tabla 3), y una referencia bajo carga concurrente en N = 20 000
(1 escritor + 1 lector, Moto G35 5G) llevada como un stress test de
estado estable. Los dos juntos cubren el envelope operativo
realista de un agente on-device long-running.

**Nota metodológica para las Tablas 3–6.** Las filas de la familia
SQLite (`sqlite`, `sqlite-optimized`, `sqlite-precompute`) vienen
de un sweep de mitigación aislado (Android: 3 rondas por backend,
orden randomizado; iOS: 3 rondas, dataset `dataset_iot_baseline`).
Las filas SQLite de la familia vector (`sqlite-vec` y variantes
SQLiteAI) vienen del harness vectorial alineado en dim = 384,
k = 10, p50 search latency sobre 100 queries. El path SQLiteAI iOS
requirió vendorizar la amalgamation de SQLite con
`SQLITE_ENABLE_LOAD_EXTENSION=1` dentro del bench target, porque el
libsqlite3 del sistema de Apple viene con extension loading
deshabilitado — esto está documentado como parte del artefacto
(§8.1, `experiment/backends/ios/sqlitevectorai/svai_ios.c`) y se
validó end-to-end con la suite XCTest corrible en simulador antes
del run en device.

**Tabla 3 — Storage backends, envelope ingest/retrieval en N = 200
en dispositivos físicos** (ingest µs por lectura / retrieval µs
promedio).

| Backend                  | Moto G35 5G ingest / retrieval | iPhone 12 Pro ingest / retrieval |
|--------------------------|-------------------------------:|---------------------------------:|
| Dazzle (default)         | 2 889 / 2 132                  | 185 / 411                        |
| Dazzle-Lua               | 1 345 / 1 824                  | 181 / 251                        |
| Dazzle-Pipeline          | 1 331 / 1 959                  | 143 / 444                        |
| Dazzle-HFE               | 2 312 / 1 893                  | 177 / 389                        |
| Dazzle-HLL               | 2 844 / 2 491                  | 185 / 454                        |
| **Dazzle-Precompute**    | **1 404 / 34.7**               | **267 / 129**                    |
| Valkey 8 (RESP-TCP)      | 3 754 / 3 320                  | 432 / 1 474                      |
| SQLite (default)         | 251.95 / 1 061.3               | 61.94 / 268.7                    |
| SQLite-Optimized         | 59.09 / 899.4                  | 23.64 / 199.4                    |
| SQLite-Precompute        | 207.77 / 75.0                  | 317.10 / 27.6                    |
| LMDB                     | 172 / 641                      | 100 / 346                        |
| RocksDB                  | 294 / 922                      | 169 / 424                        |
| ObjectBox $\ddagger$     | 1 839 / 778                    | 4 840 / 638                      |
| In-memory (struct)       | 9.97 / 282                     | 5.35 / 204                       |

$\ddagger$ El ingest de ObjectBox iOS bajó de 24 780 µs/r a 4 840
µs/r (5.1× speedup) una vez que envolvimos el cuerpo de cada
`ingest()` y `storeCheckpointDecision()` en
`store.runInTransaction { ... }`. El port Kotlin corre ~10 calls
de `box.put()` / `box.query()` por lectura y depende del
write-tx batching implícito por-call de ObjectBox-Java para
alcanzar 1 839 µs/r; ObjectBox-Swift abre una transacción de
escritura nueva por cada call (lock + journal append + fsync), así
que las mismas 10 llamadas sin coalescing pagan el overhead del
lock 10×. El gap remanente de ~2.6× iPhone-vs-Moto es consistente
con el allocator iOS y el overhead FFI observado en otras partes de
la tabla (ver la anomalía del footprint Dazzle iOS discutida en
§6.3); no es un bug del bench-harness.

**Tabla 4 — Vector backends, envelope ingest/retrieval en N = 200
en dispositivos físicos** (ingest µs por lectura / p50 search
latency µs, dim = 384, k = 10).

| Backend                   | Moto G35 5G ingest / search | iPhone 12 Pro ingest / search |
|---------------------------|----------------------------:|------------------------------:|
| **Dazzle-Vector (HNSW)**  | **74 / 65**                 | **25.17 / 18**                |
| sqlite-vec default        | 23.62 / 916.0               | 27.64 / 196                   |
| sqlite-vec optimized      | 9.66 / 860.0                | 20.67 / 193                   |
| sqlite-vec precompute     | 9.35 / 816.7                | 19.72 / 181                   |
| SQLiteAI default          | 6.08 / 135.3                | 6.90 / 29                     |
| SQLiteAI optimized        | 5.98 / 135.0                | 6.82 / 29                     |
| SQLiteAI precompute       | 5.17 / 111.3                | 7.27 / 23                     |

Dazzle-Vector en el Moto G35 5G ahora reporta **74 µs/r ingest, 65
µs p50 search a recall 1.000 (HNSW, ef = 10)** en N = 200. La
celda previa `— / —` en esta fila se debió a un bug del harness en
`SqliteBruteforceVector.create()` (la truth-source SQLite
brute-force nunca borraba su database entre runs porque el delete
de archivo apuntaba al directorio incorrecto, así que la truth de
top-k por config se computaba contra ~20 000 docs obsoletos
acumulados a través de bench launches previos; solo la última
config en cualquier sweep recuperaba fortuitamente recall por
encima del piso de 0.95). Ambos fixes aterrizaron en esta revisión:
el delete de la truth-source ahora resuelve a
`context.getDatabasePath(...)` y `VectorBenchmark` emite `FLUSHALL`
entre configs y entre variantes de motor Dazzle así que cada
medición es per-engine y per-config en aislamiento. El fix está en
el commit `1e3d5f5` de `experiment/backends/android/core/`
(`SqliteBruteforceVector.kt` + `VectorBenchmark.kt`), y el bench
post-fix está committeado en
`research/benchmarks/results/Moto_G35_5G/vector/vecbench_moto_g35_5G_1777369156656.json`
(SHA-256 `5a64d3692da166d96306d456697e43bb89c27c07b515e253346c5b33bc5c9b5b`).
Las Tablas 4, 5, 11 y el N-sweep de §5.8.4 / companion-report leen
de este único JSON, así que los números celda-por-celda y la
narrativa de recall vienen de un solo run en device, no de una
mezcla de snapshots pre-fix y post-fix.

**Observación 1.** Dazzle-Precompute fija el piso alcanzable cuando
los agregados materializados se exponen como primitiva nativa. El
retrieval promedia 34.7 µs en N = 200 en Moto G35 5G y 47 µs en
N = 20 000 bajo carga concurrente. El costo de retrieval es plano
en N porque el bloque de contexto materializado se reconstruye en
el path de escritura y se lee con una copia de campo de tiempo
constante. En iPhone 12 Pro el retrieval aterriza en 129 µs. Estos
números son la cota inferior que un backend puede alcanzar cuando
el patrón de lectura del agente está compilado dentro del schema,
no lo que cualquier backend "podría" alcanzar en principio.

**Observación 2.** Una concesión honesta que la tabla ahora hace
explícita, sobre las nueve variantes de la familia SQLite
(default/optimised/precompute sobre storage SQLite, sqlite-vec, y
SQLiteAI): el retrieval Android se mueve de 1 061.3 µs (`sqlite`
default) a 899.4 µs (`sqlite-optimized`) y a 75.0 µs
(`sqlite-precompute`). Eso cierra la mayor parte del gap de
storage-latency y refuerza el framing del paper. El diferenciador
no es un límite intrínseco del algoritmo SQLite, sino cuánta
ceremonia de materialización y código de mantenimiento debe poseer
la aplicación.

**La Observación 3 es la que realmente importa.** Incluso la
latencia de retrieval más alta del envelope (SQLite a 3 374 µs bajo
carga concurrente en Moto G35 5G) es aproximadamente el 0.0001 % de
un solo turno de inferencia Gemma 4 E2B [@gemma4] (1–3 segundos).
La diferencia perceptible para el usuario entre 50 µs y 3 374 µs en
la capa del agente es cero; ambos quedan empequeñecidos por la
llamada de inferencia que se sienta inmediatamente después del
retrieval. Las comparaciones en microsegundos no son el eje sobre
el cual elegir un backend. Los criterios dominantes son la
superficie primitiva (Tabla 1, §2.2) y la complejidad de desarrollo
requerida para entregar una capa de estado funcional (§5.6).

### Por qué seguimos reportando los microsegundos exactos

Un revisor puede razonablemente preguntar: si cada retrieval está
por debajo del piso de ruido de inferencia y las comparaciones en
microsegundos no son el eje de elección, ¿por qué §5 gasta doce
tablas enumerando microsegundos? Dos razones, ambas independientes
de la tesis del agente:

**(i) Consumidores no-LLM pueden compartir la capa de storage.**
Aunque este paper no los benchmarkea, el mismo path de código
Dazzle es estructuralmente compatible con dashboards de analítica
on-device, pipelines de pre-agregación de sensores, y capas de
resolución de conflictos de sync — cargas donde las primitivas de
retrieval (agregados materializados, bounded streams, HyperLogLog,
HNSW) son las mismas pero donde la latencia de retrieval *no* está
dominada por un forward pass de LLM. Reportamos los números
absolutos en microsegundos para que un lector evaluando esas cargas
pueda extraer la fila relevante de la Tabla 3 / Tabla 5 / Tabla 11
directamente sin re-correr el bench. No hacemos ningún claim
competitivo sobre la posición de Dazzle en esas cargas en este
momento.

**(ii) Los números absolutos son un sanity check sobre la
arquitectura.** Un backend que se vaya a 100 ms+ en N = 200 (un
orden de magnitud por encima de lo que reportamos aquí) sugeriría
una regresión digna de investigar más allá del piso de ruido LLM.
El patrón Write-Heavy / Read-Light está supuesto a mantener el
retrieval acotado; si una revisión futura rompe eso, la columna
exacta de microsegundos en T3 es donde la regresión se manifiesta.
La misma lógica para la ablación de §5.4 y la tabla de evolución de
performance de §5.7 en el companion report: esos números son cómo
sabemos que el patrón arquitectónico se mantiene intacto a través
de revisiones, no cómo recomendamos elegir un backend.

Esta sección por tanto establece que todos los backends medidos se
ubican dentro del envelope aceptable para un agente LLM on-device.
El resto de la evaluación se lee en dos tracks: **(a)** para un
lector centrado en el agent-loop, la superficie primitiva (Tabla 1)
y la complejidad de desarrollo (Tabla 9) impulsan la selección de
backend; **(b)** para un lector no-LLM, los números por motor en
microsegundos son el input directo. Ambas lecturas vienen de los
mismos datos; la diferencia es qué eje tratará el lector como el
headline.

## 5.3 Retrieval constante en N y footprint de almacenamiento

**Tabla 5 — Promedio de latencia de retrieval a través de tamaños
de dataset, Moto G35 5G** (µs). Sweep en
N $\in$ \{200, 1 000, 5 000, 20 000\}. Cada celda en la Tabla 5 y
la Tabla 5b es la media aritmética por-run de la ventana de
retrieval-sample (`retrieval_avg_us` en cada `scale_<backend>_*.json`);
para backends con múltiples sweep runs en el repo (típicamente
3–4), la celda es la mediana de esas medias por-run. La columna
correspondiente `retrieval_p50_us` también está persistida en cada
JSON para cualquier lector que prefiera la mediana sobre la media,
pero los valores de la tabla a lo largo de esta sección son medias.

| Backend                        | N = 200  | N = 1 k  | N = 5 k  | N = 20 k |
|--------------------------------|---------:|---------:|---------:|---------:|
| **Dazzle-Precompute**          | **37**   | **29**   | **29**   | **34**   |
| **Dazzle-Incremental**         | 325      | 163      | 155      | 146      |
| InMemory                       | 663      | 314      | 273      | 317      |
| SQLite (default)               | 1 061.3  | 739.1    | 717.4    | 721.6    |
| SQLite-Optimized               | 899.4    | 508.1    | 514.5    | 505.4    |
| SQLite-Precompute              | 75.0     | 59.8     | 62.1     | 60.6     |
| sqlite-vec default             | 916.0    | 1 445.7  | 7 271.0  | 27 850.3 |
| sqlite-vec optimized           | 860.0    | 1 434.7  | 7 145.3  | 28 574.7 |
| sqlite-vec precompute          | 816.7    | 1 430.7  | 7 421.3  | 26 505.3 |
| SQLiteAI default               | 135.3    | 303.0    | 1 475.0  | 9 812.3  |
| SQLiteAI optimized             | 135.0    | 302.3    | 1 591.7  | 9 569.7  |
| SQLiteAI precompute            | 111.3    | 233.3    | 889.0    | 3 071.7  |
| LMDB                           | 1 130    | 841      | 1 398    | 1 986    |

**Tabla 5b — Promedio de latencia de retrieval a través de tamaños
de dataset, iPhone 12 Pro** (µs). Misma métrica (media aritmética
de la latencia per-sample de retrieval, `retrieval_avg_us`) y misma
grilla de sweep que la Tabla 5.

| Backend                        | N = 200 | N = 1 k | N = 5 k | N = 20 k |
|--------------------------------|--------:|--------:|--------:|---------:|
| **Dazzle-Precompute**          | **25.4**| **17.8**| **17.8**| **17.8** |
| **Dazzle-Incremental**         | 139.2   | 63.7    | 63.3    | 63.2     |
| InMemory                       | 148.9   | 149.3   | 106.4   | 55.8     |
| SQLite (default)               | 73.4    | 47.5    | 47.7    | 46.7     |
| SQLite-Optimized               | 75.9    | 38.2    | 32.9    | 33.1     |
| SQLite-Precompute              | 6.88    | 3.75    | 3.79    | 3.83     |
| sqlite-vec default             | 196     | 548     | 3 578   | 15 038   |
| sqlite-vec optimized           | 193     | 547     | 3 535   | 15 200   |
| sqlite-vec precompute          | 181     | 548     | 3 535   | 15 145   |
| SQLiteAI default               | 29      | 96      | 441     | 2 850    |
| SQLiteAI optimized             | 29      | 96      | 440     | 2 842    |
| SQLiteAI precompute            | 23      | 79      | 355     | 1 407    |
| LMDB                           | 167.4   | 67.2    | 46.9    | 85.8     |

Las Tablas 5 y 5b deben leerse como un resultado de patrón de
implementación, no como una carrera de backends. La propiedad
relevante es **retrieval constante en N** cuando el sistema sirve
agregados materializados en lugar de reconstruir contexto desde
historia cruda en query time. La fila Dazzle-Precompute en la
Tabla 5 es la mediana de las medias por-run de cuatro sweep runs.
Dazzle-Precompute y Dazzle-Incremental proveen este patrón
nativamente: el trabajo de agregación se paga en escritura, y el
retrieval lee estado materializado acotado. SQLite también puede
realizar retrieval cuasi-constante cuando el mismo patrón se
implementa explícitamente. Por tanto, el comportamiento constante
en N es una propiedad del approach de agregados materializados, no
una propiedad propietaria de un solo motor.

### Footprint de almacenamiento después de 200 ingests

**Tabla 6 — Footprint en disco después de 200 ingests, por
dispositivo** (KB).

| Backend                  | Moto G35 5G (KB) | iPhone 12 Pro (KB) |
|--------------------------|-----------------:|-------------------:|
| **Dazzle (default)**     | **6.7**          | **153.3**          |
| Dazzle-Lua               | 6.6              | 153.3              |
| Dazzle-Pipeline          | 6.7              | 153.3              |
| Dazzle-HFE               | 6.6              | 153.3              |
| Dazzle-HLL               | 7.0              | 177.6              |
| Dazzle-Precompute        | 7.7              | 153.5              |
| Valkey 8 (RESP-TCP)      | 7.9              | 177.4              |
| LMDB                     | 72.0             | 176.0              |
| ObjectBox                | 96.0             | 268.0              |
| RocksDB                  | 4 515.8          | 104.0              |
| SQLite                   | 374.2            | 3 635.2            |
| SQLite-Optimized         | 494.6            | 3 391.5            |
| SQLite-Precompute        | 495.6            | 176.6              |
| sqlite-vec default       | 4.1              | 4.0                |
| sqlite-vec optimized     | 4.1              | 4.0                |
| sqlite-vec precompute    | 4.1              | 4.0                |
| SQLiteAI default         | 12.3             | 12.0               |
| SQLiteAI optimized       | 12.3             | 12.0               |
| SQLiteAI precompute      | 12.3             | 12.0               |

El ratio de headline es **Dazzle vs SQLite**:

- Moto G35 5G: 6.7 KB vs 374.2 KB — **56× más pequeño**
- iPhone 12 Pro: 153.3 KB vs 3 635.2 KB — **24× más pequeño**

El footprint es la restricción binding sobre hardware IoT y móvil
de presupuesto donde el budget de flash y el bandwidth de DRAM son
ambos escasos. Un payload **24–56× más pequeño** es la diferencia
entre que los datos de Dazzle quepan en un puñado de líneas de
caché L2 por retrieval, versus barrer múltiples páginas de SQLite
por query — lo que se compone hacia atrás en la imagen de
retrieval-latency de §5.2.

## 5.4 Ablación factorial 2³: ¿qué capa contribuye?

El stack Dazzle compone tres optimizaciones independientes:
snapshot cache (on/off), bucket dispatch por hash (1 bucket vs 16),
worker pool paralelo (off/on). Medimos seis combinaciones válidas
sobre la misma carga: K = 8 agentes, mix 80/20 read/write, 15 s por
celda.

**Tabla 7 — Throughput en K = 8, Moto G35 5G** (ops/s, mix 80/20
read/write, 15 s por celda).

| Backend              | baseline | workers | snap-ser   | snap-par | hash-ser | hash-par |
|----------------------|---------:|--------:|-----------:|---------:|---------:|---------:|
| `dazzle-incremental` | 12 106   | 9 604   | **28 897** | 28 154   | 27 926   | 28 304   |
| `dazzle-precompute`  | 19 676   | 10 988  | **38 830** | 38 754   | 38 367   | 38 156   |

Tres observaciones cuantificadas:

1. **El snapshot cache solo es la capa de throughput.**
   `snap-linear-serial` (snapshot on, 1 bucket, sin workers) es el
   pico en ambas filas: **38 830 ops/s** para precompute y **28 897
   ops/s** para incremental. Capear el hash-index de 16 buckets y
   el worker pool paralelo encima del cache (la columna "full-stack"
   `hash-par`) realmente entrega **38 156 / 28 304 ops/s** —
   `snap-ser` está 1.8 % por encima de `hash-par` para precompute y
   2.1 % por encima para incremental. El stack completo pierde, no
   gana, contra `snap-ser`; los deltas están dentro de la varianza
   run-to-run, así que la lectura práctica es "el snapshot cache por
   sí solo es suficiente y las otras dos capas no agregan nada
   medible sobre esta carga".
2. **Los workers solo regresan performance.** Sin un cache contra
   el cual hacer dispatch, el worker pool es puro overhead de
   queueing: 44 % más lento para precompute, 21 % más lento para
   incremental.
3. **El hash-index es future-proofing.** El keyspace de 4–5 keys
   del benchmark cabe trivialmente en un solo bucket; el dispatch
   O(1) se vuelve visible solo cuando el keyspace crece a docenas
   de keys o cuando los nombres de campo comparten prefijos largos.

En una línea: **el snapshot cache es la única capa que mueve
throughput sobre esta carga. El worker pool paralelo y el dispatch
hash-index son no-ops aquí y solo ganan su costo sobre cargas con
un keyspace más grande o más contendido.**

## 5.5 Validación cross-platform: iPhone 12 Pro

El mismo stack Dazzle corrido en un iPhone 12 Pro físico (iOS 26.3,
A14 Bionic) y un Moto G35 5G físico (Android 14, Unisoc T760), 200
lecturas, un solo escritor + 100 muestras de retrieval (mismo
protocolo storage-only que §5.2).

**Tabla 8 — Resumen Dazzle cross-platform, Moto G35 5G vs
iPhone 12 Pro** (N = 200, un solo escritor + 100 muestras de
retrieval).

| Métrica                              | Moto G35 5G | iPhone 12 Pro |
|--------------------------------------|------------:|--------------:|
| Dazzle-Precompute ingest (µs/r)      | 1 404       | 267           |
| Dazzle-Precompute retrieval avg      | **34.7 µs** | **129 µs**    |
| Dazzle-Precompute retrieval P50      | 34.3 µs     | 139 µs        |
| Dazzle-Precompute retrieval P95      | 42.2 µs     | 189 µs        |
| Dazzle-default retrieval avg         | 2 132 µs    | 411 µs        |
| Ganancia de retrieval (precompute/default) | 61×   | 3.2×          |
| Footprint (Dazzle default)           | 6.7 KB      | 153.3 KB      |
| Footprint vs SQLite                  | 56× menor   | 24× menor     |

Tres observaciones sobre el comportamiento cross-platform:

1. **La forma arquitectónica generaliza.** Dazzle-Precompute le gana
   al path Dazzle default en ambas plataformas — el trade-off
   Write-Heavy / Read-Light se mantiene en ambas direcciones del
   par SoC + OS. El snapshot cache paga en cada lectura sin importar
   dónde corra.

2. **Los números absolutos de retrieval son sensibles a la
   plataforma.** Moto G35 5G aterriza en 34 µs P50; iPhone 12 Pro
   en 139 µs P50. El gap de 4× lo impulsa el path RESP del
   Valkey-fork in-process en iOS (tokio runtime + bridge Rust→Swift
   por retrieval), no el snapshot cache en sí. El path Android usa
   un bridge JNI más delgado con menos hops por call.

3. **La dirección del ingest se invierte.** El Moto necesita
   1 404 µs por lectura; el iPhone necesita 267 µs (5.3× más barato
   en iPhone). Los cores más rápidos del A14 Bionic más el
   bandwidth LPDDR4X tragan la secuencia per-reading de
   `XADD` + `HINCRBYFLOAT` + `HSET` más rápido que el tier de
   presupuesto Unisoc T760.

El resumen: la **contribución arquitectónica generaliza** sobre
hardware y OS (el costo se desplaza de read a write, el snapshot
cache absorbe N, el footprint se mantiene a escala de un solo
motor), mientras que **los números absolutos varían por SoC y stack
de runtime**. Incluso sobre el path de retrieval iPhone más lento,
el P95 se mantiene bajo 200 µs. Eso es tres a cuatro órdenes de
magnitud bajo el forward pass LLM on-device ($>10^{6}$ µs en
cualquier dispositivo), que sigue siendo el único término que
importa al nivel del agent-loop.

## 5.6 Complejidad de desarrollo

**Tabla 9 — Líneas de código por backend, desagregadas por
plataforma** (SLOC: blanks y líneas de puro comentario excluidas;
los counts Kotlin usan el archivo Android `*ContextManager.kt` en
`experiment/backends/android/` y los counts Swift usan el archivo
iOS `*ContextManager.swift` en `experiment/backends/ios/`. Menor
es mejor; cada fila implementa la misma superficie de capa de
estado del agente).

| Backend       | Android (Kotlin) SLOC | iOS (Swift) SLOC | Suma (ambas) | Estilo de API                          |
|---------------|----------------------:|-----------------:|-------------:|----------------------------------------|
| **Dazzle**    | **175**               | **186**          | **361**      | Comandos de primitivas tipados         |
| InMemory      | 174                   | 172              | 346          | Manipulación directa de colecciones    |
| LMDB          | 200                   | 227              | 427          | API byte-buffer                        |
| RocksDB       | 203                   | 227              | 430          | API byte-buffer con options            |
| ObjectBox     | 233                   | 245              | 478          | Anotaciones de schema + DSL            |
| SQLite        | 268                   | 292              | 560          | SQL + cursor mapping                   |

El desglose por dos plataformas importa porque el port Android y
el port iOS de un backend se trackean entre sí dentro de ~30 SLOC
para cada fila excepto SQLite (+24 en iOS, mayormente marshalling
de result-row con C-API que la API `Cursor` de Android oculta). El
ordering relativo es estable a través de plataformas: Dazzle es el
backend más bajo no-InMemory en ambas, SQLite es el más alto, y el
gap entre Dazzle y SQLite es ~93 SLOC en Android y ~106 SLOC en
iOS — ligeramente más amplio en iOS.

Dazzle requiere el menor número de líneas porque su API tipada
(`XADD`, `HMGET`, `PFADD`) expresa directamente las operaciones del
dominio del agente sin schema translation ni cursor parsing.

## 5.7 Evolución de performance (resumen)

El stack actual es el resultado de cinco rediseños de transporte
in-process. La contribución individual más grande es el
**auto-mirror post-EVAL (+189 % sobre throughput de retrieval
incremental** en K = 8, Moto G35 5G, mix 80/20 read-write), que
hidrata el snapshot cache desde escrituras Lua-internas sin
ceremonia manual. Agregar el snapshot index buckedeado, el worker
pool paralelo, y el HSET inline en el script Lua contribuye un
~14 % adicional sobre precompute. La tabla completa
versión-por-versión (baseline 9 684 ops/s → final 28 057 ops/s en
incremental, 34 356 → 38 156 en precompute) vive en §1 del companion
engineering report (`research/paper/companion_engineering_report.md`).
Cada optimización fue verificada como una contribución
independiente; el cambio se persiste en el repo y en el JSON de
benchmark archivado, no se pierde a través de revisiones.

## 5.8 Primitiva de búsqueda vectorial: envelope y operating points

El resultado que importa en esta sección es un envelope claim, no
un speed-competition claim: **la búsqueda vectorial HNSW de Dazzle
entrega retrieval sub-milisegundo a recall $\geq 0.95$ a lo largo
del rango operativo estándar de mobile RAG ($\dim \leq 384$,
$N \leq 10\,000$)**. Eso pone a Dazzle en la misma clase
algorítmica que ObjectBox 4.x, el peer comercial mobile-first con
soporte HNSW nativo: ambos son HNSW [@hnsw] con búsqueda esperada
$O(\log N)$.

SQLiteAI sqlite-vector v0.9.95, la extensión SQLite comercial
production-shipping al cierre de Q1 2026, expone un linear scan
acelerado por SIMD cuantizado (`vector_quantize_scan`) como su
único query path optimizado; HNSW no es user-accessible en esta
versión. Incluir SQLiteAI es informativo como referencia de lo que
los desarrolladores móviles del ecosistema SQLite encuentran hoy,
pero esta comparación abarca dos clases algorítmicas
($O(\log N)$ vs $O(N)$); el gap resultante refleja esa asimetría,
no la calidad de ingeniería de ninguna implementación.

El contrato del harness para cada celda de recall floor /
operating-point en esta sección está documentado, auditado, y
post-mortemeado en el Apéndice B
(`research/paper/appendix_b_harness_postmortem.md`). Cada celda en
las Tablas 4, 11 y 12 viene del run post-fix archivado en
`research/benchmarks/results/Moto_G35_5G/vector/vecbench_moto_g35_5G_1777369156656.json`
(commit `1e3d5f5`, SHA-256 citada en §5.2).

### 5.8.1 Setup — dos presets de harness

La evaluación vectorial corre el mismo harness
(`VectorBenchmark.kt` en Android, `VectorBenchmark.swift` en iOS)
contra dos grillas de configuración distintas. El resto de §5.8
cita cualquiera dependiendo de la pregunta a responder:

| Preset                       | Configs | Usado en           | Qué responde |
|------------------------------|--------:|--------------------|--------------|
| `DEFAULT_CONFIGS`            | 9 (3 dim $\times$ 3 N) | §5.8.3 envelope claim   | "¿Dazzle se mantiene sub-milisegundo a lo largo del rango mobile RAG estándar (dim $\leq$ 384, N $\leq$ 10 000)?" |
| `vector-bench-paper384-scale` (Android) / `paper384_scale` (iOS) | 4 (1 dim $\times$ 4 N) | T11 + T12 + T13 + T14 | "¿Cuál es el operating point en la escala headline del paper, y cómo escala a N = 20 000?" |

La grilla de 9 configs barre **{16, 128, 384}** dim $\times$ **{500,
2 000, 10 000}** N para caracterizar la forma del envelope. La
grilla de 4 configs fija dim = 384 y barre N $\in$ **{200, 1 000,
5 000, 20 000}** así que el operating point reportado en T11
(N = 20 000) está en la misma grilla que el N-sweep de la familia
SQLite en T12–T14. Ambas grillas corren k = 10 nearest neighbours,
distancia coseno, recall floor recall@10 $\geq 0.95$, p50 / p95 /
p99 sobre 100 queries por celda en estado estable warm (descartando
cold cache).

Configuraciones:

- **Dazzle HNSW (float32)**: M=32, efConstruction=400, efRuntime
  variado en {10, 50, 100, 200}.
- **Dazzle SQ8 (int8 + NEON SDOT)**: mismos build params HNSW, más
  cuantización scalar en el path de storage con NEON dot-product en
  el path de comparación.
- **ObjectBox 4.x**: HNSW vía la anotación `@HnswIndex`,
  configurada con los mismos M=32, efConstruction=400, distancia
  coseno, vectores float32.
- **SQLiteAI 0.9.95**: `vector_init` con FLOAT32 + coseno,
  `vector_quantize(max_memory=50MB)` para construir el snapshot
  int8, `vector_quantize_preload` para warmear el cache, queries a
  través de `vector_quantize_scan` (linear scan sobre vectores
  cuantizados).

### 5.8.2 Tabla de operating-point

**Tabla 11 — Comparación de operating point por motor vectorial en
dim = 384, N = 20 000, k = 10, recall@10 floor $\geq 0.95$** (p50
search latency en µs, ingest total en ms, DB size en disco para
motores de la familia SQLite, `INFO memory → used_memory_dataset`
para las filas in-memory Dazzle/Valkey).

| Engine / Variant         | Algorithm             | Precision | Recall@10 | p50 search ‡ | Ingest (ms) | RAM / DB size          |
|--------------------------|-----------------------|-----------|----------:|-------------:|------------:|-----------------------:|
| **Dazzle SQ8**           | HNSW + int8 SDOT      | int8      | 0.959     | **208 µs** [203, 212] |      16 614 | 9.77 MB $\dagger$      |
| Dazzle SQ8+Rerank        | HNSW + int8 + fp32    | int8/fp32 | 0.982     | 330 µs       |      14 966 | 39.06 MB $\dagger$     |
| Dazzle F16               | HNSW + fp16           | fp16      | 0.984     | 297 µs       |      26 082 | 17.09 MB $\dagger$     |
| Dazzle HNSW              | HNSW                  | float32   | 0.952     | 343 µs       |      43 028 | 31.74 MB $\dagger$     |
| ObjectBox 4.x            | HNSW                  | float32   | 0.994     | 853 µs [853, 1 078] |     387 405 | not reported by runner |
| sqlite\_plain            | linear scan           | float32   | 1.000     | 707 302 µs   |       1 614 | 79.45 MB               |
| sqlite\_vec\_default     | linear scan           | float32   | 1.000     |  27 391 µs   |       1 316 | 31.00 MB               |
| sqlite\_vec\_optimized   | linear scan           | float32   | 1.000     |  28 575 µs   |         869 | 31.00 MB               |
| sqlite\_vec\_precompute  | linear scan           | float32   | 1.000     |  26 505 µs   |         870 | 31.00 MB               |
| SQLiteAI default $*$     | quantized linear scan | int8      | 0.987     |   3 087 µs   |         723 | 46.65 MB               |
| SQLiteAI optimized $*$   | quantized linear scan | int8      | 0.987     |   2 842 µs   |         685 | 46.65 MB               |
| SQLiteAI precompute $*$  | quantized linear scan | int8      | 0.987     |   1 407 µs   |         708 | 46.65 MB               |

‡ El intervalo `[lo, hi]` entre corchetes al lado de las dos celdas
headline de la misma clase (Dazzle SQ8, ObjectBox 4.x — ambos HNSW)
es un **CI 95 % bootstrap percentile-method cross-run sobre el
estadístico p50** [@efronbootstrap; @davisonhinkley] computado
sobre los cuatro runs independientes post-fix Moto G35 5G
archivados en `research/benchmarks/results/Moto_G35_5G/vector/`
(timestamps 2026-04-28T05:05Z / 05:21Z / 09:24Z / 09:39Z;
B = 10 000, seed = 42; script
`research/scripts/bootstrap_vecbench_cross_run.py`; full report en
`research/paper/vecbench_cross_run_ci.md`).

$*$ Las tres filas SQLiteAI son **single-shot del run cross-engine**
(el mismo paper384_scale pass que produjo cada otra fila en esta
tabla). El sweep dedicado de la familia SQLite de 3 rondas en el
mismo N = 20 000 reporta `default` 9 812 ± 363 µs, `optimized`
9 570 ± 548 µs, `precompute` 3 072 ± 4 µs (companion report §2,
Tabla 2). Mantenemos el número cross-engine aquí para que cada fila
de la Tabla 11 esté en el mismo contexto de medición.

$\dagger$ Las filas Dazzle/Valkey corren in-process y el bench no
ejerció un path de persistencia en disco (BGSAVE estaba
deshabilitado para mantener el costo de I/O fuera de la medición).
Para poner las filas Dazzle en la misma columna que los números
`db_file_bytes` de la familia SQLite, reportamos el **footprint
analítico de RAM/disk** en su lugar, computado como
`(N × dim × bytes_per_component) + (N × M × 4)` — los vectores más
el grafo HNSW (listas de vecinos int32, `M = 32` por nodo).

El head-to-head justo es Dazzle vs ObjectBox: ambos motores corren
HNSW.

A recall floor $\geq 0.95$ (el operating point común de mobile
RAG), Dazzle SQ8 alcanza 208 µs p50 search en N = 20 000 contra
ObjectBox 4.x en 853 µs — 4.1× más rápido, ambos sobre HNSW. A
recall estricto $\geq 0.99$ la imagen se invierte en el eje de
recall: ObjectBox mantiene un recall más alto (0.994 vs 0.959 para
Dazzle SQ8 en $ef = 10$) y Dazzle SQ8 se ubica en un operating
point de recall menor en esta configuración. Eso es un trade-off
esperado entre la cuantización int8 que Dazzle SQ8 usa y la
precisión float32 que ObjectBox mantiene, no una contradicción.

SQLiteAI sigue siendo una referencia secundaria útil porque es el
path SQLite production en muchos stacks móviles. El ratio observado
contra SQLiteAI en N = 20 000 es consistente con comportamiento
$O(\log N)$ vs $O(N)$ y debe leerse con esa nota algorítmica
adjunta.

### 5.8.3 Interpretación del envelope

A lo largo de la grilla de 9 configuraciones, Dazzle se mantiene en
el envelope de search sub-milisegundo para el rango móvil objetivo
y ObjectBox permanece en el mismo orden de magnitud bajo settings
HNSW alineados. La conclusión de ingeniería relevante es que ambos
sistemas son elecciones HNSW-class viables para RAG on-device, con
distintos trade-offs de constante-factor según el operating point y
el target de recall.

Versiones futuras de SQLiteAI sqlite-vector se espera que expongan
HNSW. En ese punto la comparación significativa se desplazará de
asimetría de clase algorítmica a análisis de constante-factor entre
dos implementaciones HNSW.

### 5.8.4 Sweep de variantes de extensión SQLite — resumen

> **Disclosure de clase algorítmica.** Esta subsección compara
> Dazzle SQ8 (HNSW, search $O(\log N)$ esperada) contra SQLiteAI
> sqlite-vector v0.9.95 (linear scan cuantizado acelerado por SIMD,
> $O(N)$). Los dos sistemas están en **clases algorítmicas
> distintas**, no en la misma clase con constantes diferentes. Los
> ratios numéricos reportados abajo son por tanto *referencias de
> envelope* — describen qué tan adentro o afuera del envelope de
> search sub-milisegundo aterriza cada path en un operating point
> mobile-RAG representativo — y **no claims de calidad de motor**
> sobre SQLiteAI como producto.

Para cerrar el gap del "single SQLite path" corrimos un N-sweep
focalizado en Moto G35 5G sobre backends vectoriales solo de la
familia SQLite — `sqlite_plain`, `sqlite_vec` y SQLiteAI en sus
variantes `default` / `optimized` / `precompute` — en dim = 384,
k = 10, 100 queries, 3 rondas, N $\in$ {200, 1 k, 5 k, 10 k,
20 k}. La fila de operating-point N = 20 000 para cada variante
está mergeada en la Tabla 11 arriba.

La lectura es **sobre membresía del envelope, no una declaración de
ganador**. En N = 20 000, dim = 384, k = 10, recall $\geq 0.95$:

* **Dazzle SQ8** aterriza en 208 µs (Tabla 11) — claramente dentro
  del envelope de search sub-milisegundo.
* `sqlite_vector_ai_precompute` aterriza en **1 407 µs** en el
  cross-engine single-shot (Tabla 11) y en **3 072 ± 4 µs** medio a
  través del sweep dedicado de 3 rondas — fuera del envelope
  sub-milisegundo, en milisegundos de un solo dígito.
* `sqlite_vec` (linear scan brute-force) está consistentemente por
  encima de ambas lecturas SQLiteAI.

El factor 6.8×–14.8× entre Dazzle SQ8 y SQLiteAI precompute en este
N es por tanto *evidencia de que el path HNSW se mantiene dentro
del envelope sub-milisegundo mientras que el path linear-scan cruza
al rango de los milisegundos* — i.e., documenta un threshold de
tamaño de corpus más allá del cual la elección del motor empieza a
importar al nivel del agent-loop.

## 5.9 Aplicación end-to-end en Moto G35 5G: small-model + RAG on-device

> **Alcance de esta sección.** La ablación RAG end-to-end reportada
> abajo se corrió originalmente sobre un solo dispositivo físico
> (Motorola Moto G35 5G, Unisoc T760, cluster A76 ARMv8.2). §5.9.5
> extiende el run a un segundo SoC Android físico (Motorola Moto
> G30, Qualcomm Snapdragon 662, cluster A73 ARMv8.0) y reproduce
> la 2×2 con CIs 95 % superpuestos en cada celda — tres de las
> cuatro celdas son bit-idénticas (Q4_K_M + greedy decoding +
> retrieval idéntico determinizan el token stream) y la cuarta
> difiere por 0.005 en el punto estimado. La cobertura end-to-end
> en iPhone 12 Pro queda como trabajo futuro; la validación
> storage-path en iPhone 12 Pro ya aparece en §5.5.

La tesis de esta sección es a nivel de aplicación: la
disponibilidad de una primitiva vectorial in-process habilita un
patrón de agente cualitativamente distinto — small-model + RAG
on-device [@lewisrag; @karpukhindpr] — que puede alcanzar accuracy
factual mayor que un modelo más grande sin retrieval. La pipeline
completa corre on-device, sin cloud y sin servidor externo,
incluido en un teléfono Android de \$150. El corpus de 2 K passages
que indexamos también mantiene cada passage retrieved bien dentro
de la ventana de contexto del small-model, así que los artefactos
de precisión-de-retrieval causados por degradación de
contexto-largo [@liulostmiddle] no están en el path entre el índice
y la respuesta.

### 5.9.1 Setup

Indexamos 2 000 passages de un mini-slice determinista de Natural
Questions [@nq2019] en un Motorola Moto G35 5G (Unisoc T760, 4 GB
RAM, Android 14). Los passages y los pares (question, gold-passage)
vienen del split SBERT pair de NQ [@sbertnq]; los aliases de
short-answer canónicos se joinean desde `nq_open` [@nqopen;
@leeorqa] por texto de pregunta lowercased.

**Precondición de aliases.** No cada NQ question tiene short-answer
canónico en `nq_open` — el join produce un campo `short_answers`
solo para el subset de questions que los autores de NQ-open
anotaron. Pre-filtramos el pool de candidatos para mantener solo
questions con al menos un short-answer alias, después sampleamos
200 de esos (así cada query en el bench tiene un set de
ground-truth no-vacío para `EM_short` / `F1_short`). Los 2 000
passages se construyen como los 200 gold positives más 1 800
distractors random sacados del mismo pool, seed 42; los passages se
truncan a 1 800 caracteres para caber en el contexto de 512 tokens
de `bge-small-en-v1.5`. El slice es regenerable desde
`research/scripts/nq_slice.py` y está fingerprinted por el prefijo
sha256 `63be4b8894c71ff3` (provenance completa en
`research/data/nq_slice/README.md`).

Embeddings producidos con `bge-small-en-v1.5` [@bgesmall] (q4_k_m,
24 MB, dim 384, n_ctx 512); índice Dazzle HNSW_SQ8 con M=32,
efC=400. Para cada uno de los 200 queries hacemos retrieve de los
k=5 passages más cosine-similar con efRuntime=64 y los inyectamos
en el prompt. Configuraciones:

- **Qwen 2.5 0.5B Instruct + Dazzle RAG.** GGUF q4_k_m, 380 MB en
  disco. n_ctx=2 048. Prompt formado como `<system>… <retrieved
  passages>… <user question>`. Decoding greedy,
  max_new_tokens=64.
- **Qwen 2.5 1.5B Instruct sin RAG.** GGUF q4_k_m, 940 MB en
  disco — 2.5× más grande, 3× más parámetros. n_ctx=2 048. Prompt
  formado como `<system> <user question>`. Decoding greedy,
  max_new_tokens=64.

**Protocolo de evaluación.** Para cada query el modelo genera hasta
64 tokens. Extraemos el span de respuesta predicho `y_pred` como el
prefijo de la generación hasta la primera newline o eco fresco
`Question:` / `Answer:`. Tanto `y_pred` como el short-answer gold
`y_gold` se normalizan siguiendo el protocolo SQuAD v1.1 [@squad]
(lowercasing, removal de los artículos `{a, an, the}` y
puntuación, collapsing de whitespace).

Reportamos tres métricas de short-answer más un backup de passage:

- **`EM_short`** (estricto) — `1` iff `norm(y_pred) == norm(y_gold)`
  para cualquier alias, `0` en otro caso.
- **`F1_short`** — F1 a nivel token (whitespace tokenisation) entre
  `norm(y_pred)` y el alias `norm(y_gold)` que mejor matchea,
  promediado sobre queries.
- **`EM_contains`** (laxo) — `1` iff los tokens normalizados de
  cualquier alias aparecen como substring contiguo en alguna parte
  de la generación *completa*. Esto separa *"el modelo sabe la
  respuesta"* de *"el modelo responde concisamente"*.
- **`F1_passage`** — token-F1 entre `y_pred` (whitespace tokens, sin
  normalización agresiva) y el passage gold completo; mide si la
  generación reproduce el contexto de soporte.

### 5.9.2 Resultado — matriz 2×2 completa

**Tabla 15 — Accuracy factual end-to-end RAG sobre 200 queries NQ**
(Moto G35 5G; decoding greedy, max\_new\_tokens = 64; mismo bench
run para las cuatro celdas; raw JSON en
`research/benchmarks/results/Moto_G35_5G/rag_2x2/rag_e2e_moto_g35_5G_1777395311213.json`,
SHA-256 `00d21f6c8752ffaa1015624b69a5e5d0fd403670d72561e3838bdac0ab461e76`).

Cada celda se reporta como point estimate con el CI 95 % bootstrap
percentile-method `[lo, hi]` sobre la array per-query de la métrica
(n = 200, B = 10 000, seed = 42). El report bootstrap completo
(CIs por celda, ratio CIs paired-qid sobre las 16 celdas
métrica × ratio, flags de significancia) vive en
`research/paper/rag_2x2_with_ci.md` y es regenerable desde el mismo
JSON vía `research/scripts/bootstrap_rag_metrics.py`.

| Configuración             | Tamaño  | EM\_short                | EM\_contains             | F1\_short                | F1\_passage              |
|---------------------------|---------|--------------------------|--------------------------|--------------------------|--------------------------|
| Qwen 0.5B (sin RAG)       | 380 MB  | 0.015 [0.000, 0.035]     | 0.105 [0.065, 0.150]     | 0.079 [0.055, 0.106]     | 0.151 [0.138, 0.164]     |
| Qwen 0.5B + Dazzle RAG    | 380 MB  | **0.120** [0.080, 0.165] | **0.630** [0.565, 0.695] | **0.235** [0.191, 0.283] | 0.334 [0.300, 0.369]     |
| Qwen 1.5B (sin RAG)       | 940 MB  | 0.045 [0.020, 0.075]     | 0.110 [0.070, 0.155]     | 0.118 [0.084, 0.154]     | 0.085 [0.073, 0.098]     |
| Qwen 1.5B + Dazzle RAG    | 940 MB  | **0.220** [0.170, 0.275] | **0.735** [0.670, 0.795] | **0.331** [0.282, 0.380] | 0.387 [0.355, 0.420]     |

Leyendo la matriz 2×2 a través de filas y columnas (los CIs de
ratios son bootstrap paired-qid; ★ marca aquellos cuyo CI 95 %
excluye 1.0):

- **Lift por adición de RAG** (mismo modelo, with-RAG vs no-RAG):
  `EM_contains` 0.630 vs 0.105 en 0.5B (**6.0×** $\bigstar$),
  0.735 vs 0.110 en 1.5B (**6.7×** $\bigstar$); `EM_short` 0.120
  vs 0.015 en 0.5B (**8.0×** $\bigstar$), 0.220 vs 0.045 en 1.5B
  (**4.9×** $\bigstar$).
- **El modelo más pequeño con retrieval supera al modelo más
  grande sin retrieval en cada métrica factual.** 0.5B + RAG vs
  1.5B sin RAG: `EM_contains` 0.630 vs 0.110 (**5.7×**), `EM_short`
  0.120 vs 0.045 (**2.7×**), `F1_short` 0.235 vs 0.118 (**2.0×**),
  `F1_passage` 0.334 vs 0.085 (**3.9×**).

### 5.9.3 Latency vs accuracy frontier

La capacidad cruda del modelo y el retrieval contribuyen
aditivamente. El 1.5B + RAG (0.220 EM_short / 0.735 EM_contains) es
el máximo global, pagando un costo de p50 per-turn de 49 s. Para
contexto del frontier:

- 0.5B sin RAG: 2.50 s p50 per-turn, 0.015 EM_short.
- 0.5B + RAG: 17.6 s p50 per-turn, 0.120 EM_short.
- 1.5B sin RAG: 2.98 s p50 per-turn, 0.045 EM_short.
- 1.5B + RAG: 49.0 s p50 per-turn, 0.220 EM_short.

El gap dominante de latencia entre filas RAG y no-RAG son los
~5 KB de passages retrieved (k=5, ~1 KB cada uno) que el modelo
tiene que prefill en cada turno. En decoding token los runs RAG y
no-RAG decodifican aproximadamente el mismo número de tokens
(`max_new_tokens=64`); el delta de latencia es prácticamente todo
prefill cost. El path de retrieval-de-storage en sí (HNSW search
sobre 2 000 passages) es ~0.6 ms en wall clock — invisible en este
gráfico.

Lo que importa es que el **patrón RAG está disponible on-device sin
dependencia de cloud**; la contribución del backend de storage a
ese turn budget es el costo de ~22 ms + 0.6 ms embed-and-search —
bajo el 0.05 % del row RAG total más rápido.

### 5.9.5 Extensión cross-platform a tres SoCs Android y un SoC Apple

Para chequear que las conclusiones de §5.9 no son artefactos de un
solo chip — ni de un solo OS — re-corrimos la 2×2 completa sobre
tres dispositivos adicionales que cubren dos sistemas operativos:

- un Motorola Moto G30 (Qualcomm Snapdragon 662, cluster
  Cortex-A73, baseline ARMv8.0, 4 GB LPDDR4, Android 11);
- un Huawei P20 Lite ANE-LX3 (HiSilicon Kirin 659, Cortex-A53,
  baseline ARMv8.0, 4 GB LPDDR4, Android 9.1 / EMUI 9 / kernel 4.9);
- un **Apple iPhone 12 Pro** (Apple A14 Bionic, cores Firestorm +
  Icestorm, ARMv8.4 + ISA Apple-private, 6 GB unified memory, iOS
  26) — la única fila no-Android, ejercitando el port Swift de
  `RagE2EBench` en `experiment/llm/ios/` sobre los mismos entry
  points C `dazzle_llama_*` y `dazzle_vs_*` que el JNI Android usa
  en las otras tres filas.

Las cuatro filas corrieron con los mismos archivos de modelo, el
mismo slice NQ de 2 000 passages (prefijo sha256
`63be4b8894c71ff3`), y el mismo build de Dazzle (`libdazzle.so`
baseline en Android v8.0, `libdazzle_v82.so` en Android v8.2,
static `libvalkey-server.a` en iOS — todos derivados del mismo
árbol de fuentes `core/platform/dazzle_llama.cpp` +
`sdk/android/src/main/cpp/valkeysearch_module.cc`). Greedy
decoding, passages retrieved idénticos, token streams idénticos.

**Tabla 17 — Reproducción cross-platform §5.9. Medias `F1_short`
con CIs 95 % bootstrap-percentile (B = 10 000, seed = 42). Greedy
decoding, mismos pesos de modelo, mismo slice NQ. Las ratios con
estrella colapsan el par (numerador, denominador) en un único test
de significancia contra 1.0 bajo paired-qid resampling. Las filas
del Kirin 659 e iPhone 12 Pro corren con `Algorithm.FLAT` en
lugar de `HNSW` (sidebar items 6 y 13); el recall de FLAT a esta
escala (N = 2 000, dim = 384, k = 5) es > 99 %, por lo que
`F1_short` por celda difiere a lo más ~0.005 entre los dos
algoritmos — dentro del CI por celda.**

| Chip | µarch | ISA | RAM | OS | Algo | small no-RAG | small + RAG | large no-RAG | large + RAG |
|------|-------|-----|-----|-----|------|--------------|-------------|--------------|-------------|
| Unisoc T760 (Moto G35 5G) | A76 | v8.2 | 6 GB | Android 14 | HNSW | 0.079 [0.055, 0.105] | 0.235 [0.191, 0.283] | 0.118 [0.084, 0.154] | 0.487 [0.431, 0.542] |
| QCOM SD662 (Moto G30) | A73 | v8.0 | 4 GB | Android 11 | HNSW | 0.079 [0.055, 0.105] | 0.240 [0.195, 0.287] | 0.118 [0.084, 0.154] | 0.487 [0.431, 0.542] |
| HiSi Kirin 659 (Huawei P20 Lite) | A53 | v8.0 | 4 GB | Android 9 | FLAT | 0.079 [0.055, 0.105] | 0.236 [0.191, 0.283] | 0.119 [0.085, 0.155] | 0.484 [0.427, 0.539] |
| **Apple A14 (iPhone 12 Pro)** | **Firestorm** | **v8.4+** | **6 GB** | **iOS 26** | **FLAT** | **0.079 [0.055, 0.105]** | **0.236 [0.191, 0.283]** | **0.119 [0.085, 0.155]** | **0.488 [0.432, 0.543]** |

Los tres chips reproducen las mismas cuatro celdas dentro del CI
por celda. Tres de las cuatro celdas (`small no-RAG`, `large
no-RAG`, `large + RAG`) son bit-idénticas entre T760 y SD662; la
fila del Kirin matchea con ambos a ≤ 0.003 — el delta de recall
FLAT vs HNSW y la selección de kernel ggml v8.0 vs v8.2 contribuyen
juntos menos que el half-width del CI con `B = 10 000` en cada
celda.

La fila del Kirin 659 reporta el run tal como completó sobre el
chip después de una **investigación de quince passes** (deadlock de
HNSW `addPoint(label = 0)` → fallback a `Algorithm.FLAT`;
acumulación del kill-score de iAware en EMUI 9 a través del embed
loop → driver multi-process de cuatro fases; segfault SIMD del path
FLAT del SDK sobre Cortex-A53 → scan brute-force escalar portable
sobre un mirror `fp32_store`; deadlock LLM en split-prefill sobre
prompt de 570 tokens con `n_batch = 512` → `n_batch = n_ctx`;
iAware mata el bench process alrededor de la query 30/200 en las
variantes Qwen 1.5B → 20 chunks de 10 queries cada uno, un
`am instrument` fresh por chunk, partials concatenados en el merge
— ver `research/results/cross_platform_e2e/
ane_lx3_kirin659_investigation.md`). Con los cinco fixes
shippeados, la fila del Kirin es **directamente comparable** a los
chips HNSW y las ratios son idénticas:

| Chip | small + RAG / large no-RAG | small + RAG / small no-RAG | large + RAG / large no-RAG |
|------|----------------------------|----------------------------|----------------------------|
| Unisoc T760 | 2.00× [1.44, 2.89] ★ | 2.97× [2.05, 4.51] ★ | 4.13× [3.10, 5.86] ★ |
| QCOM SD662 | 2.03× [1.47, 2.95] ★ | 3.03× [2.09, 4.58] ★ | 4.13× [3.10, 5.86] ★ |
| HiSi Kirin 659 | 1.98× [1.43, 2.88] ★ | 2.98× [2.06, 4.54] ★ | 4.07× [3.04, 5.74] ★ |
| **Apple A14** | **1.98× [1.43, 2.88] ★** | **2.98× [2.06, 4.54] ★** | **4.10× [3.07, 5.80] ★** |

Los tres enunciados sobre retrieval-como-palanca-dominante (§5.9.4
en versión EN) se sostienen sobre los cuatro SoCs en dos OSes al
mismo nivel de significancia. La reproducción también confirma que
**las conclusiones de §5.9 son claims sobre el storage engine, no
sobre el LLM runtime ni sobre el OS runtime**: los chips difieren
~11× en throughput LLM bruto (p50 de `large + RAG`: iPhone 12 Pro
30.84 s, T760 49.23 s, SD662 71.99 s, Kirin 659 152.26 s) pero las
ratios de F1 que sostienen la tesis de §5.9 son estables. La fila del Kirin también confirma la tesis de
storage-engine desde la dirección opuesta: retrieval (scan escalar
FLAT @ ~2.5 ms p50 para N = 2 000, dim = 384) e ingest
(addBatchDirect 47 ms para N = 2 000) operan sobre los presupuestos
default del SDK incluso sobre un chip Cortex-A53 / 4 GB del 2017,
así que la surface del engine documentada en este paper es portable
sobre las tres generaciones de microarquitectura Android testeadas
(A76, A73, A53).

**Descomposición de latencia.** Partir el `total_us p50` por
query en sus cuatro componentes del pipeline (`embed` = forward
de BGE sobre la pregunta, `search` = retrieval vector, `prefill`
= LLM ingiere prompt + passages retrieved, `decode` = LLM
autoregresivo hasta `max_new_tokens = 64`) afina la tesis de
storage-engine a un statement de presupuesto:

**Tabla 18 — small + RAG descomposición de latencia (mediana por
query, ms). Prefill domina, retrieval es < 0.13 % del total en
cada chip incluyendo Cortex-A53 del 2017 y Apple A14 del 2020; la
ratio `prefill ≈ 6× decode` que el perfil compute-vs-memory de
Qwen 2.5 fija es invariante a través de microarquitecturas *y*
sistemas operativos.**

| Chip | embed p50 | search p50 | prefill p50 | decode p50 | total p50 |
|------|-----------|------------|-------------|------------|-----------|
| Apple A14 (iPhone 12 Pro) | 14.2 | 1.7 | 11 835 | 2 016 | 13 576 |
| Unisoc T760 | 21.5 | 0.6 | 15 027 | 2 924 | 17 618 |
| QCOM SD662 | 30.8 | 0.9 | 22 237 | 4 387 | 26 237 |
| HiSi Kirin 659 | 67.4 | 3.7 | 48 374 | 9 138 | 56 159 |

Dos invariantes visibles sobre los tres chips:

1. **`prefill ≈ 6× decode`.** El prefill compute-bound (cada
   token lee el KV cache completo) y el decode memory-bound
   (cada token streamea una vez) sientan en la misma ratio de
   FLOPs por token que Qwen 2.5 especifica, sin importar la
   microarquitectura. T760 es 3.2× más rápido que Kirin en
   términos absolutos, pero el split intra-query es el mismo.
2. **`embed + search ≪ 1 % de `total_us``** en cada celda:

   | Chip | embed | search | prefill | decode | retrieval / total |
   |------|-------|--------|---------|--------|-------------------|
   | Apple A14 (iPhone 12 Pro) | 0.10 % | 0.012 % | 87.2 % | 14.9 % | **0.12 %** |
   | Unisoc T760 | 0.12 % | 0.003 % | 85.3 % | 16.6 % | **0.13 %** |
   | QCOM SD662 | 0.12 % | 0.004 % | 84.8 % | 16.7 % | **0.12 %** |
   | HiSi Kirin 659 | 0.12 % | 0.007 % | 86.1 % | 16.3 % | **0.13 %** |

   La tesis de storage-engine de §5.9 colapsa a un statement de
   presupuesto, no a un argumento de tuning: una regresión de
   un orden de magnitud en el path de retrieval (e.g. bajar el
   recall de HNSW a 80 % o correr FLAT brute-force a 5× los ms
   que cuesta en Kirin) todavía dejaría el retrieval bajo 1.5 %
   del total, bien dentro del noise floor del prefill. La
   spread 3× wall-clock entre chips es 100 % LLM-runtime; el
   engine documentado en este paper ni ayuda ni perjudica ese
   envelope.

**Techo de recall del retrieval.** Una pregunta natural a la
descomposición de latencia es si el pipeline de retrieval es el
bottleneck del F1 de §5.9. Computar `recall@k` de BGE-small sobre
las mismas 200 queries NQ contra el mismo corpus de 2 000 passages
— scoreando "el gold passage de short-answer está en el top-k"
contra el campo `gold` de cada query — da el F1 upper bound que el
storage engine *podría* entregar al LLM:

**Tabla 19 — recall@k de retrieval de BGE-small sobre el slice de
200 queries NQ. Cosine sobre embeddings unit-normalisados de
`dim = 384`. Un solo número por row porque los embeddings son
determinísticos y el chip elegido no cambia el recall — mismo
modelo, mismo corpus, mismas queries.**

| k    | recall@k |
|------|----------|
| 1    | 0.905    |
| 3    | 0.970    |
| 5    | 0.980    *(paper config)* |
| 10   | 0.990    |

El pipeline de retrieval entonces entrega el gold passage en el
top-5 en 98 % de las queries — pero `F1_short` aterriza en 0.487
para `large + RAG` sobre el chip más fuerte. El gap de 49 puntos
entre "retrieval perfecto" y "el modelo escribe la respuesta
correcta" es **la quality de extraction del LLM, no el recall del
storage engine**. El small Qwen 2.5 0.5B compone esto — `small +
RAG` aterriza en 0.236, la mitad del número del large-model,
sobre el mismo contexto de 0.98 recall. Un modelo class-7B
cerraría la mayor parte del gap remanente sin cambiar una línea
del código del engine en este paper; la surface del storage
engine satura su upper bound sobre este corpus y ships cero
budget bloqueante sobre F1.

> **Sidebar de ingeniería — fixes de portabilidad shipped durante
> este sweep cross-platform.** Cinco issues SDK-level surgieron al
> llevar el bench más allá del target original Moto G35 5G. Cada
> uno está documentado en `research/results/cross_platform_e2e/`
> y el fix correspondiente se shipped en la rama
> `kirin-4gb-sdk-opts`:
>
> 1. **`flash_attn` requiere `asimdhp`.** El path flash-attention
>    de llama.cpp emula conversión fp16↔fp32 sobre cores sin
>    half-precision nativa (Cortex-A53 / A73 baseline v8.0), lo
>    que hace el path más lento y usa *más* working memory que el
>    kernel estándar. Cambiar el default de `flashAttention` a
>    `CpuFeatures.hasFp16()` en lugar de `true` incondicional
>    mantiene el path lento fuera de chips que no pueden usarlo.
> 2. **`n_batch` del embedder capeado bajo `n_ctx` divide
>    passages largos en prefills multi-batch, lo que deadlockea
>    en cores v8.0 dentro del fallback fp16 de ggml.** El slice
>    NQ de §5.9 tiene al menos un passage de ~450 tokens
>    (`passages[2]`); el default SDK `n_batch = min(n_ctx, 256)`
>    para el embedder dividía ese prefill en 256 + 194 sub-batches
>    y se congelaba en Kirin 659 / SD662 v8.0. Subir el default a
>    `n_batch = n_ctx` (= 512) evita el path split en cada passage
>    del slice.
> 3. **El paralelismo de `addBatchDirect` bulk no auto-throttle.**
>    El pool default de 8-way `std::thread` deadlockea bajo CPU
>    cgroup throttling agresivo (EMUI iAware), donde el kernel no
>    puede mantener calientes los 8 workers y los threads spinean
>    sobre el mutex per-element de hnswlib. Exponer
>    `VectorIndex.setAddBatchThreads(n)` y un env var
>    `DAZZLE_HNSW_BATCH_THREADS` matching permite que un device
>    tight-RAM pin el build pool a un solo worker sin cambiar
>    parámetros del paper.
> 4. **La importance del foreground-service notification debe ser
>    ≥ HIGH en EMUI 9.** El channel previo `IMPORTANCE_LOW` causaba
>    que el bench process se demote a `WORKINGSET_BACKGROUND`
>    (subCmd 352 de iAware) ~10 s después del foreground grant
>    sin importar wakelock o whitelist de batería; subir la
>    importance del channel y agregar un re-`notify` heartbeat de
>    4 s es el workaround diagnosticado.
> 5. **Runs lanzados por activity en EMUI 9 requieren
>    `am start -a MAIN -n` (la forma con `-c LAUNCHER` re-routea
>    via HwLauncher y descarta extras del intent).**
>    Runs lanzados por instrumentation pasan por encima del
>    iAware throttling completamente; el harness ahora ships un
>    JUnit entry point `RagE2EBenchTest` invocable via
>    `am instrument`, con la misma surface de extras del intent
>    que la activity lee.
> 6. **HNSW `addPoint(label = 0)` deadlockea sobre Cortex-A53 +
>    libstdc++ Bionic.** La primera llamada a
>    `hnswlib::HierarchicalNSW::addPoint` bloquea indefinidamente
>    en Kirin 659 / EMUI 9 / kernel 4.9 incluso con un
>    `addBatchDirect` single-thread y un load mínimo de vectores
>    random (4 vecs, dim = 4), confirmando que el bug está en la
>    lib, no en el bench. `Algorithm.FLAT` (BruteforceSearch) es
>    exacto y termina en 47 ms sobre N = 2 000, dim = 384 — la
>    fila del Kirin de la Tabla 17 reporta bajo FLAT. La causa
>    raíz del deadlock está documentada en ocho passes de
>    investigación; el SDK va a hacer fallback automático a FLAT
>    sobre chips que matchean el fingerprint en v3.
> 7. **El kill-score de iAware en EMUI 9 acumula a través del embed
>    loop y dispara sobre el siguiente mmap grande.** Incluso con
>    el workaround FLAT shipped, el bench process es killed en
>    silencio en `DazzleLlm.open` después de un embed loop de 25
>    min exitoso — sin importar `useMmap`, `useMlock`, `n_threads`
>    o pre-warm. Un probe standalone de instrumentation en un
>    proceso fresh abre el mismo Qwen 0.5B en 1.5 s y exit limpio,
>    confirmando que el kill es el score per-process de iAware, no
>    un límite OS-wide del hardware. El harness ships un driver
>    multi-process de cuatro fases (`RagE2EBenchPhases`) que parte
>    el bench en invocaciones separadas de `am instrument`:
>    `phase=embed` escribe embeddings a un cache binary,
>    `phase=small` corre las variantes Qwen 0.5B en un proceso
>    fresh (variant A + variant C back-to-back), y `phase=large`
>    corre las variantes Qwen 1.5B en otro.
> 8. **El path FLAT del SDK mal-conectado a través de
>    `BruteforceSearch` de hnswlib, que segfaultea sobre NEON
>    Cortex-A53.** Con (7) shippeado el bench todavía obtenía 0.025
>    en `small + RAG` (vs 0.235 en los chips HNSW) porque
>    `RagE2EBenchPhases.ensureServerRunning` arrancaba Valkey sin
>    `DazzleModule.VectorSearch`, así que `FT.CREATE` no tenía
>    handler y el schema per-index nunca aterrizaba en `g_indexes`
>    — `addBatchDirect` / `searchDirect` JNI-direct retornaban en
>    silencio con 0 hits. Con el módulo cargado, la siguiente capa
>    del bug emergió: el SIMD distance kernel de
>    `BruteforceSearch::searchKnn` de hnswlib segfaultea sobre
>    loads NEON 16-byte misaligned sobre el stride packed
>    `[vec, label]` que hnswlib usa, en Cortex-A53 + libstdc++
>    Bionic. El fix mirrorea cada vector del path FLAT en
>    `schema->fp32_store` y reemplaza `searchKnn` con un scan
>    brute-force escalar portable; ~2.5 ms por query sobre N =
>    2 000, dim = 384 en Cortex-A53. El path HNSW no cambia.
> 9. **Split-prefill del LLM deadlockea en Cortex-A53 v8.0 cuando
>    el largo del prompt excede `n_batch`.** Con (7) y (8) shipped,
>    el bench pasaba las fases de embed y addBatch pero el bench
>    process era killed dentro de segundos de la primera query
>    `+RAG` en `DazzleLlm.generate`. Las variantes `no-RAG`
>    completaban — distinto code path, prompt de ~30 tokens. El
>    prompt `+RAG` es de ~570 tokens y `cfg.llmNBatch = 512`, así
>    que llama.cpp partía el prefill en una primera call de 512
>    tokens + una continuación de 58 tokens, golpeando el mismo
>    fallback fp16 ggml v8.0 que el item 2 documentó para el
>    embedder. Subir `llmNBatch` a `llmNCtx` (= 2048) hace prefill
>    de cualquier prompt hasta el context size en una sola call;
>    las queries `+RAG` entonces completan con
>    `prompt_tokens.avg = 570` matcheando T760 / SD662.
> 10. **iAware re-dispara después de ~30 queries de `Qwen-1.5B +
>     RAG` incluso con los items 7–9 aplicados.** La variante D
>     (large + RAG) consistentemente muere entre query 5 y query
>     30 a través de reboots y reinstalaciones. El harness del
>     bench ahora ships un runner chunked de variantes
>     (`runRagE2EVariantChunk` con extras `q_offset` / `q_limit`)
>     para que cada chunk corra en un proceso `am instrument`
>     fresh y los archivos JSON per-chunk sean concatenados por
>     la fase de merge. La fila del Kirin de la Tabla 17 fue
>     producida por 20 chunks de 10 queries para variant D más 4
>     chunks de 50 queries para variant B; wall clock total para
>     Phase 2b ≈ 8 hr 50 min.
> 11. **Watchdog de launch iOS (`0x8BADF00D`) en el primer run de
>     RagE2EBench.** El bench monolítico `RagE2EBench.run()` invocado
>     inline desde `DazzleExperimentApp.init()` agota el watchdog de
>     launch de 20 segundos de iOS antes de que SwiftUI tenga chance
>     de renderizar, así que FrontBoard mata el proceso con
>     `0x8BADF00D ProcessVisibility:Foreground`. Fix: dispatchear el
>     bench en `DispatchQueue.global(qos: .userInitiated).async`
>     desde `init()` para que el main runloop de SwiftUI agende la
>     view placeholder dentro de la ventana del watchdog. El bench
>     termina ~25–35 min después en background queue y se hace
>     `exit(0)` solo. Mismo fix lands como utility public en el
>     entry point Swift de `RagE2EBench.run()` así cualquier app iOS
>     que use el entry point obtiene el dispatch automático.
> 12. **Default `n_batch < n_ctx` del context LLM en iOS gatilla
>     split prefill en prompts largos.** Con (11) shippeado, el
>     bench iPhone pasaba embed + addBatchDirect pero el proceso
>     era killed dentro de 1 s de la primera query `+RAG` en
>     `llama_decode` — mismo pattern que el pass 15 del Kirin
>     documentó para Android v8.0, esta vez en el build de
>     llama.cpp iOS. `dazzle_llama_new_context` shippeaba con
>     `n_batch = 512` hard-coded; el prompt de §5.9 es ~570 tokens
>     así que `llama_decode` parte el prefill en 512 + 58
>     sub-batches y el continuation aborta. Fix: setear
>     `n_batch = n_ctx` en `dazzle_llama_new_context` para que
>     cualquier prompt hasta context size hace prefill en una sola
>     llamada `llama_decode`. El cambio aplica en cada plataforma;
>     cuesta ~30 MB extra de compute buffer a `n_ctx = 2048`,
>     despreciable vs los pesos del modelo.
> 13. **Método convenience Swift `DazzleServer.vectorIndex(...)`
>     sin `initialCapacity`.** Con (11) y (12) shippeados, el bench
>     pasaba la fase LLM pero `addBatchDirect` abortaba en el
>     elemento 1024 con
>     `BruteforceSearch::addPoint runtime_error("exceeds limit")`
>     de hnswlib porque el index FLAT se creaba con el default SDK
>     `INITIAL_CAP = 1024`. El bench Kotlin Android pasaba 2 000
>     vía el ctor low-level `vectorIndex(...)` que acepta
>     `initialCapacity`; el método convenience Swift en
>     `DazzleServer.shared.vectorIndex(...)` no lo exponía. Fix:
>     extender la firma `DazzleServer.vectorIndex` iOS con
>     `initialCapacity: Int = 0` (más `m`, `efConstruction`) para
>     que los callers puedan pre-sizear como en el lado Android.
>
> Los items 1–5 son fixes universales de portabilidad que landed
> sobre los cuatro chips. Los items 6–10 son específicos del path
> Kirin 659 y los items 11–13 específicos del port iOS; ninguno
> cambia la comparación numérica de las celdas de la Tabla 17.
> Juntos cierran el gap entre "el bench corrió sobre el chip
> donde lo desarrollamos" y "el bench corre sobre un spread de
> SoCs Android mid-range y un SoC Apple sobre dos sistemas
> operativos" — una precondición para cualquier claim
> cross-platform / cross-OS sobre una superficie de engine
> embebida.

# 6. Discusión

## 6.1 Agregados materializados como primitiva, no como optimización

El retrieval de baja latencia en este paper monta sobre el patrón
de agregados materializados, no sobre alguna marca específica de
motor de base de datos. Ya sea implementado como un hash mantenido
por Lua en Dazzle, una tabla mantenida por triggers en SQLite, o
un step explícito de update en una estructura in-memory, el patrón
desplaza el trabajo de agregación al write time y hace bounded el
retrieval en read time.

La contribución de Dazzle no es inventar este patrón. La
contribución es entregarlo como una superficie primitiva
first-class (`EVALSHA`-maintained hash + `HMGET`) con acceso SDK
tipado, así que el autor de la aplicación no necesita construir
lógica de migración, orquestación de triggers, o código de
mantenimiento manual para cada app.

Esta distinción importa para la tesis del paper: en el envelope de
latencia donde todos los backends son aceptables, el factor
decisivo es menos "¿puede existir el patrón?" y más "cuánta
ceremonia de ingeniería se requiere para hacerlo correcto y
mantenible en producción".

## 6.2 El bloque de contexto bounded

La propiedad de ~58–62 tokens independiente de N viene de una
decisión arquitectónica, no de coincidencia. El bloque de contexto
codifica seis escalares agregados (min/max/avg/count/…) más el
sumario probabilístico, no una lista de N lecturas crudas. El
tamaño del prompt por tanto se desacopla del tamaño del dataset:
un agente corriendo durante semanas en un dispositivo no debería
consumir progresivamente más de la ventana de contexto del modelo
simplemente porque más datos se han acumulado.

## 6.3 Limitaciones

- **Superficie primitiva contada como API nativa, no como
  equivalencia expresiva.** La Tabla 1 (§2.2) reporta
  disponibilidad de primitivas como un check categórico (`N` API
  nativa / `E` extensión oficial / `A` re-implementación a nivel
  de aplicación / `T` extensión third-party) sobre cómo el backend
  llega a cada construcción, con el conteo headline medido solo
  sobre `N`. Las primitivas marcadas `E`, `A` o `T` para backends
  no-Dazzle son *implementables* atómicamente a través de las
  facilidades general-purpose del motor subyacente — por ejemplo,
  range queries de sorted-set vía `ORDER BY` + `WHERE BETWEEN` en
  SQLite, increments atómicos de float vía
  `UPDATE … SET v = v + ?` dentro de una transacción, indexación
  geográfica vía la extensión `R*Tree` de SQLite (extensión
  oficial enviada con la SQLite amalgamation desde 2008), bounded
  `MAXLEN` streams vía triggers, y TTL vía un job `DELETE`
  programado. La señal de la Tabla 1 es por tanto "cuánto código
  pegamento escribe el autor del agente para alcanzar esta
  primitiva" (una cuestión ergonómica de superficie primitiva que
  ata de vuelta a la Tabla 9), no "esta funcionalidad es
  alcanzable en este motor", que en casi cada caso, sí.
- **Post-mortem del harness.** Un bug en la truth-source
  `SqliteBruteforceVector` causó que data obsoleta se acumulara a
  través de configuraciones del benchmark recall-floor en v1; fue
  arreglado en el commit `1e3d5f5` y cada celda de las Tablas 4,
  11 y 12 de esta revisión viene del run post-fix. La timeline
  completa (introducción, detección, fix, asserts que atrapan una
  regresión futura, y una auditoría de cada otro benchmark
  on-device en el repo por el mismo bug pattern) está documentada
  en el Apéndice B
  (`research/paper/appendix_b_harness_postmortem.md`).
- Evaluación end-to-end LLM en un solo dispositivo físico (Moto
  G35 5G) + validación cross-platform en iPhone 12 Pro. Los
  resultados en otros SoCs y versiones OS pueden diferir; los
  reportamos en tres familias adicionales de SoC Android (Unisoc,
  MediaTek, Qualcomm) en companion benchmark reports.
- Carga sintética. Streams reales de IoT tienen patrones bursty,
  fallos de sensor, y concurrencia adicional que no modelamos.
- La evaluación de accuracy del modelo usa tres estadísticas
  verificables; una evaluación más rigurosa usaría un set de
  preguntas factuales más grande y múltiples runs por condición.
- Paridad de transporte iOS/Android incompleta: el SPSC ring
  buffer y el path `io_uring` son Linux-only; iOS se queda sobre
  el Phase-0 pipe path, suficiente para la carga evaluada (§5.5).
- **Carga LLM end-to-end de un solo dispositivo.** El bench
  end-to-end RAG de §5.9 se reporta en un solo dispositivo físico
  (Moto G35 5G).
- **Los peers comerciales evolucionan.** SQLiteAI v0.9.95 no
  expone HNSW al cierre de este bench; una versión futura del
  producto que incluya HNSW desplazaría la comparación de §5.8 de
  "HNSW vs brute-force scan" a "HNSW vs HNSW", reduciendo el gap
  a constant factors en lugar de asimetría algorítmica.
- **Skew de footprint allocator-platform.** El tamaño on-disk e
  in-memory de un backend embebido es sensible al allocator host
  y a la configuración default. Observamos un delta cross-platform
  de 23× sobre Dazzle (153 KB en iOS vs 6.7 KB en Android, mismo
  Valkey-fork in-process, misma carga de 200 lecturas) atribuible
  al `libsystem malloc` de Apple versus el comportamiento de la
  arena `jemalloc` de Android, y un delta de 42× sobre RocksDB
  en la dirección opuesta (4.41 MB Android vs 104 KB iOS) impulsado
  por los defaults de pre-allocation WAL + SST de Android.
- **Comparación de configuración default en §5.2.** La comparación
  storage-latency usa configuraciones de backend default. Un setup
  SQLite con vistas materializadas mantenidas manualmente vía
  triggers cerraría la mayor parte del gap medido. La contribución
  de Dazzle es shipear el patrón nativamente, no claimar
  superioridad algorítmica sobre SQLite.
- **El benchmark vectorial abarca dos clases algorítmicas.** En
  §5.8, Dazzle y ObjectBox corren HNSW (O(log N)), mientras que
  SQLiteAI v0.9.95 expone brute-force quantized scan (O(N)). Una
  release futura de SQLiteAI con HNSW user-accessible
  desplazaría la comparación a constant factors.
- **El benchmark de aplicación RAG aísla disponibilidad de
  retrieval, no identidad de motor vectorial.** La sección §5.9
  compara with-retrieval vs without-retrieval y no aísla el motor
  vectorial de Dazzle contra ObjectBox o SQLiteAI en la misma
  pipeline end-to-end.
- **Sesgo de autor sobre la medición LOC.** El autor de este paper
  es también el autor de las seis implementaciones de backend
  contra las que Dazzle se mide en la Tabla 9. Los managers
  Dazzle-side fueron los primeros escritos y los más iterados; los
  managers SQLite/LMDB/RocksDB/ObjectBox son ports directos de la
  misma superficie de capa de estado del agente pero no fueron
  optimizados subsecuentemente por line count.
- **Conflicto de interés y compromiso público.** El autor de este
  paper es también el autor de `dazzle-sdk` (Apache-2.0; Maven
  Central / pub.dev / npm / Swift Package Manager) y de cada
  wrapper de comparison-engine benchmarkado aquí. Para hacer la
  comparación falsificable en lugar de auto-servida, tres
  compromisos concretos sostienen desde la fecha de esta revisión
  en adelante:

  1. **Los seis wrappers de backend son artefactos first-class en
     el repositorio.** Todo su source, build configuration, y test
     entry points viven bajo `experiment/backends/` y tienen la
     misma licencia Apache-2.0 que Dazzle. Cualquiera puede
     forkear, re-tunear, y re-correr.
  2. **External pull requests que reduzcan el LOC count de
     cualquier wrapper no-Dazzle, o que mejoren cualquier número
     medido del backend no-Dazzle en las Tablas 3 / 5 / 11, serán
     revisados y mergeados sobre mérito técnico.**
  3. **Cada optimización aceptada se registra en
     `experiment/backends/CHANGELOG.md` antes del próximo bench
     freeze.**

  La metodología del benchmark, los outputs JSON crudos, y los
  scripts de análisis están abiertos en el repositorio (paths
  listados en §8.1 Reproducibility) así que cualquier claim en el
  paper puede re-correrse contra un build independiente de los
  motores de comparación.

### Validación cross-platform del benchmark vectorial

Las Tablas 11 y 12 se reportan en un solo dispositivo físico
(Moto G35 5G, Unisoc T760, ARMv8.2-A). Para descartar artefactos
single-device, re-corrimos el mismo harness sobre tres familias
adicionales de SoC Android y re-bootstrapeamos la celda headline
N = 20 000 con paired-query resampling (`B = 10 000`, seed = 42).
Las tablas per-engine completas están en
`research/paper/vecbench_cross_platform_ci.md`; los headline
ratios se reproducen aquí:

| Device                                  | SoC (ISA, big core)                                | Round 1 p50 (dispatched) | Round 2 p50 (baseline-forced) | Δ            |
|-----------------------------------------|----------------------------------------------------|-------------------------:|------------------------------:|--------------|
| Moto G35 5G *(reference)*               | Unisoc T760 (ARMv8.2-A + fp16/dot, Cortex-A76)     |       269 [261, 273] µs  |        269 [264, 273] µs      | **0 µs**     |
| Huawei Y9a (FRL-L23)                    | MediaTek Helio G80 (ARMv8.2-A + fp16/dot, A75)     |       671 [642, 701] µs  |        588 [566, 612] µs      | **-83 µs** ² |
| Moto G30                                | Snapdragon 662 (ARMv8.0-A, Cortex-A73)             |       445 [409, 478] µs  |        519 [488, 548] µs      | +74 µs ¹     |
| Huawei P20 Lite (ANE-LX3)               | Kirin 659 (ARMv8.0-A, Linux 4.9, Cortex-A53)       |     1054 [1035, 1092] µs |     1043 [1014, 1078] µs      | -11 µs ¹     |

¹ Los chips ARMv8.0 corren la misma `libdazzle.so` baseline en
ambas rondas (la variante v82 haría SIGILL); el Δ ronda-a-ronda es
por tanto puro ruido térmico/load, ranging ±10 % en N = 20 000.

² En Helio G80 (Cortex-A75 [@armcortexa75] big core) el binario v82
dispatched es **más lento** que el baseline en ≈ 12 % en p50 (los
CI 95 % no se solapan: [642, 701] vs [566, 612] µs). Los kernels
NEON del hot-path son idénticos — `simsimd` runtime-selecciona los
mismos símbolos `_neon_f16 / _neon_dotprod` en ambos binarios — así
que el gap está en el código C++ circundante.

## 6.4 Asimetría algorítmica en el benchmark vectorial

La comparación en §5.8 abarca dos clases algorítmicas: HNSW
(Dazzle, ObjectBox) es approximate nearest neighbour search con
expected $O(\log N)$ search complexity [@hnsw]; SQLiteAI v0.9.95
implementa linear scan acelerado por SIMD $O(N)$ sobre vectores
cuantizados int8. La asimetría es por diseño del producto SQLiteAI
— `vector_quantize_scan` es el único query path optimizado que el
producto expone; HNSW no es user-accessible en esta versión.

Dentro de la Tabla 11 la lectura de operating-point es la que se
debe usar: **Dazzle SQ8 aterriza en recall = 0.959 / p50 = 208 µs,
ObjectBox 4.x en recall = 0.994 / p50 = 853 µs, SQLiteAI precompute
en recall = 0.987 / p50 = 1 407 µs**, todos en N = 20 000,
dim = 384, recall floor $\geq 0.95$.

Los dos motores HNSW (Dazzle SQ8 y ObjectBox) son **dos puntos
sobre la misma curva Pareto recall–latency**, no winner / loser:
Dazzle SQ8 trades precisión de cuantización int8 por p50 ~4× menor;
ObjectBox mantiene precisión fp32 y paga el costo de latencia.
**Ambas elecciones se mantienen dentro del envelope LLM-noise-floor
en este N**. SQLiteAI se ubica en una clase algorítmica distinta
($O(N)$ scan); su celda 1 407 µs todavía cabe en el noise floor en
N = 20 000 pero no en N $\gg 20\,000$ — el threshold de tamaño de
corpus que §5.8.4 documenta.

# 7. Trabajo relacionado

**Inferencia on-device.** LiteRT-LM, llama.cpp, MLC-LLM, y
ExecuTorch [@litertlm; @llamacpp; @mlcllm; @executorch] apuntan a
compresión de modelo y eficiencia de runtime. Ninguno aborda la
capa de ejecución stateful; cada inference call se trata como un
evento independiente.

**Memoria para agentes.** MemGPT [@memgpt] propone una jerarquía
de memoria de dos niveles (in-context + external) targeting server
deployment. Generative Agents [@generativeagents] usa un memory
stream retrieval-augmented para simulación NPC. A-MEM [@amem]
introduce memoria agent-managed con linking dinámico. Las tres
asumen entornos cloud o server con un proceso de base de datos
separado, red, y RAM substancial. Dazzle mueve esa capa de memoria
externa **dentro del proceso de la app móvil**.

**Redis sobre hardware restringido.** Redis sobre Raspberry Pi
alcanza latencia sub-milisegundo pero corre como demonio separado
sobre TCP. No conocemos un Valkey-on-Android port publicado.

**Motores embebidos.** SQLite, LMDB, y RocksDB están diseñados
desde cero como librerías in-process. Dazzle toma el path opuesto:
arranca de un motor server diseñado alrededor de TCP loopback y un
event loop single-threaded, y reescribe su substrato de I/O (no
sus estructuras de datos) para hacer ejecución in-process el
default. El resultado se sienta entre ambos campos. La biblioteca
se consume exactamente como un motor embebido, mientras que el
modelo de datos es el que un full server-grade database expone.

**Bases de datos vectoriales móviles — tres productos distintos.**
El ecosistema mobile SQLite-vector incluye tres productos
comúnmente confundidos que vale la pena distinguir aquí.
(1) **SQLite** plano no tiene soporte nativo para vectores y se
benchmarkea solo sobre su capa de storage en §5.2. (2) El
**sqlite-vec** open-source de Alex Garcia (`github.com/asg017/sqlite-vec`,
Apache 2.0) es una extensión SQLite agregando vector search
brute-force; esta revisión lo benchmarkea en el sweep
SQLite-family (§5.8.4). (3) **SQLiteAI sqlite-vector**
[@sqliteaivector] (`github.com/sqliteai/sqlite-vector`, Elastic
Licence 2.0) es el producto comercial de SQLite Cloud, Inc. (la
entidad corporativa detrás del ecosistema SQLite AI); ship un path
de query linear-scan cuantizado acelerado por SIMD
(`vector_quantize_scan`) y deliberadamente evita HNSW.
**ObjectBox 4.x** [@objectbox4] es el otro peer comercial en
nuestro benchmark y ship HNSW nativo respaldado por vectores
float32.

**Librerías ANN vectoriales server-grade.** **FAISS** [@faiss]
(Facebook AI), **DiskANN** [@diskann] (Microsoft Research), y
**Milvus** [@milvus] (Zilliz) fijan el baseline open-source para
approximate nearest-neighbour search a escala billion-point sobre
hardware server. La literatura de cuantización vectorial debajo de
esos motores — Product Quantisation [@jegoupq] en particular — es
el precedente algorítmico para el path SQ8 que Dazzle usa.

Los kernels NEON de Dazzle para fp32 dot product, fp32 L2-squared,
fp16 dot product, e i8 cosine vienen de `simsimd` [@simsimd]
(Vardanian, Apache 2.0 license) y usan el runtime dispatcher de esa
librería (`simsimd_capabilities()` sobre `/proc/cpuinfo`) para
seleccionar la mejor variante disponible en cada chip.

**Object stores móviles más allá de SQLite.** **Realm** [@realm]
(ahora MongoDB) y **WCDB** [@wcdb] (Tencent / WeChat) son los dos
peers production-deployed de ObjectBox en el espacio móvil
object-store. Ambos targetean Android + iOS, ambos ship APIs
typed más altas que SQLite raw, y ambos son ampliamente usados en
apps comerciales. Ninguno ofrece vector search o HyperLogLog como
primitiva (Realm ship full-text search; WCDB es SQLite-on-the-wire
underneath).

**Evaluación de RAG.** **RAGTruth** [@ragtruth] es el corpus
canónico de hallucination para evaluación retrieval-augmented LLM
al cierre de 2024. La sección §5.9 usa NQ-open en su lugar porque
la unidad de medición aquí es *recall de canonical short-answer
strings* (si el LLM emite el gold span cuando retrieval está
presente). RAGTruth mide hallucination *dado* contexto retrieved,
que es una señal estrictamente downstream que requiere un
hallucination judge. Layerar evaluación estilo RAGTruth sobre el
setup de §5.9 es trabajo futuro; pertenecería al mismo eje que el
reporting EM-vs-F1 que ya incluimos.

# 8. Conclusión

Dazzle propone una lente diferente de selección de backend para
agentes on-device. La superficie primitiva, la ergonomía de
desarrollador, y el envelope de latencia importan más que carreras
aisladas en microsegundos. En la carga medida cada backend evaluado
opera dentro de un envelope aceptable de retrieval; los
diferenciadores operativos son qué primitivas de agent-state están
disponibles nativamente y cuánto esfuerzo de ingeniería cuestan de
usar.

Tres resultados empíricos respaldan ese framing. La latencia de
retrieval en el path de estado estable de Dazzle es aproximadamente
0.00176 % de un solo turno de inferencia LLM on-device (50 µs
contra $\sim 2.84$ s para Gemma 4 E2B en el Moto G35 5G), lo que
ubica el costo de retrieval del backend dentro del piso de ruido
del bucle end-to-end. Superficie primitiva y esfuerzo de desarrollo
difieren materialmente: Dazzle expone diez primitivas nativas
contra $\leq 4$ en las alternativas embebidas medidas, con
implementaciones representativas de agent-state aterrizando
alrededor de 175 LOC (Android) / 186 LOC (iOS) en Dazzle contra
aproximadamente 200–290 LOC a través de las alternativas (Tabla 9,
ambas plataformas). A nivel de aplicación, una ablación 2×2 RAG
eleva `EM_contains` 6.0× sobre Qwen 2.5 0.5B (0.105 → 0.630) y 6.7×
sobre Qwen 2.5 1.5B (0.110 → 0.735); un modelo de 380 MB con
retrieval supera a un modelo 3× más grande sin retrieval en cada
métrica factual, end-to-end en un dispositivo Android de \$150.

La pregunta práctica para el próximo deployment on-device por tanto
se desplaza de "¿qué backend es más rápido?" a "¿qué set de
primitivas y qué composición de modelo encajan mejor en la
aplicación, dado que el costo de retrieval es efectivamente
invisible al nivel de turno?".

Dazzle se distribuye públicamente como `dazzle-sdk` 1.0.0-beta.4
sobre Maven Central, pub.dev, npm, y Swift Package Manager. El
código original de Dazzle se publica bajo Apache-2.0; las porciones
derivadas de Valkey retienen BSD-3-Clause. Invitamos a la comunidad
a validar estos resultados sobre hardware móvil adicional y a
extender la matriz del benchmark a través de cargas más amplias.

## 8.1 Artefacto y reproducibilidad

Para hacer la evaluación auditable, este repositorio incluye los
scripts, dataset builders, y árboles de resultados crudos usados
para producir las tablas del paper. Los componentes están
organizados así:

- **Bench runners**: `research/scripts/run_experiment.sh`,
  `run_full_benchmark.sh`, `run_ios_benchmark.sh`,
  `run_ablation_sweep.sh`,
  `run_storage_microbench_per_backend.sh`,
  `run_vector_sqlite_family.sh`.
- **Generación de dataset y RAG slice tooling**:
  `research/scripts/generate_dataset.py`, `nq_slice.py`,
  `recompute_rag_metrics.py`.
- **Análisis de resultados y generación de tablas**:
  `analyze_results.py`, `analyze_storage_microbench.py`,
  `make_vector_bench_table.py`,
  `analyze_vector_sqlite_family.py`.
- **Árboles de resultados crudos y procesados**:
  `research/benchmarks/results/`, `research/results/`.

Cada métrica headline en §5 fue computada desde estos artefactos
locales. Una guía compacta paso-a-paso de reproducción se provee
en `research/paper/REPRODUCIBILITY.md` y puede ejecutarse
end-to-end sobre el mismo workspace layout.

## 8.2 Política de versionado y compromiso público de actualización

Este paper documenta un moving target: `dazzle-sdk` es un artefacto
vivo bajo desarrollo activo a través de cuatro registries de
paquetes, los backends de comparación evolucionan, y varios
hallazgos en esta revisión son explícitamente null results que
invitan a investigación adicional. Para mantener al paper como una
referencia útil en lugar de un snapshot congelado, el autor se
compromete a la siguiente política de versionado en arXiv:

1. **Cada cambio medible en cualquier celda headline de las Tablas
   3, 5, 11, 12, o 15 produce una nueva revisión arXiv.**
2. **Cada nuevo dispositivo físico agregado a la tabla
   cross-platform (§6.3) produce una nueva revisión arXiv.**
3. **Cada PR externo aceptado que mejore los números medidos de
   un backend no-Dazzle produce una nueva revisión arXiv** — con
   el PR contribuyente citado y los números viejos preservados
   con strikethrough.
4. **El abstract arXiv lleva una fecha de "Last updated" y un
   changelog de una línea del cambio material más reciente**.
5. **Todas las mediciones JSON crudas** viven en
   `research/benchmarks/results/` bajo paths timestamped, nunca
   sobrescritas a través de revisiones. Las re-derivaciones
   bootstrap-CI son deterministas (`B = 10 000`, `seed = 42`).
6. **El branch main del repositorio es el source of truth.**
   Cuando una discrepancia surja entre una revisión arXiv y `main`,
   `main` gana; la discrepancia gatilla una revisión por (1).

El autor es alcanzable en `ivan.aliaga@urp.edu.pe` para preguntas
de revisor, issues de reproducción, y pull requests contra el
código del benchmark. Issues abiertos en el repositorio GitHub se
acknowledgean dentro de siete días; las revisiones arXiv numeradas
se procesan dentro de catorce días del trigger event.

# Referencias

Ver `research/paper/arxiv-build/refs.bib` para las entradas
bibliográficas completas. Esta versión en español preserva las
citas verbatim del paper en inglés (formato `[@key]` por entrada
bibtex). 49 referencias numeradas.

# Apéndice A — Capa de adaptadores LLM (referencia)

El SDK Dazzle expone una sola interfaz `LLMClient` (completion,
streaming, deltas de tool-call, lifecycle) y ship cinco adaptadores
concretos detrás de ella:

- **`LlamaCppClient`** — adaptador local llama.cpp, GGUF
  q4_k_m / q5_k_m / q8_0, n_ctx configurable.
- **`LiteRtLmClient`** — adaptador LiteRT-LM (Google AI Edge),
  artefactos `.litertlm` cargados via runtime LiteRT.
- **`FoundationModelsClient`** — adaptador Apple Intelligence
  (iOS 26+), enruta a Apple's on-device foundation model bridge.
- **`OpenAICompatibleClient`** — adaptador HTTP-compatible para
  llamar a APIs OpenAI-style (tanto endpoints OpenAI como
  servidores compatibles).
- **`AnthropicClient`** — adaptador para Anthropic Messages API
  [@anthropicapi].

Las cinco implementaciones residen en
`sdk/android/src/main/java/dev/dazzle/sdk/edge/` (Kotlin) y
`sdk/ios/Sources-LiteRTLM/`,
`sdk/ios/Sources-FoundationModels/` etc. (Swift), comparten la
misma interfaz tipada de `completion(prompt, params)` /
`streamCompletion(prompt, params, onDelta)`, y son intercambiables
desde el agent-loop perspective.

