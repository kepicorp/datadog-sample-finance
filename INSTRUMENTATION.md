# Finance Sample App — Instrumentation Guide

This guide walks through enabling Datadog observability layer by layer across
all six microservices. Each step is independent — complete them in order or
skip ahead to what you need.

The application runs cleanly with **zero Datadog configuration**. Every
instrumentation block is commented out by default. Uncomment, redeploy, and
validate in Datadog before moving to the next step.

---

## Prerequisites

- The app is running (locally: `make up` / on EKS: `make deploy-k8s-eks`)
- A Datadog API key is set:
  - **Docker:** `DD_API_KEY` in `deploy/docker/.env`
  - **EKS:** stored in AWS Secrets Manager, deployed by `make deploy-k8s-dd`
- The Datadog Agent is running:
  - **Docker:** `make up-dd`
  - **EKS:** `make deploy-k8s-dd`

---

## Step 1 — Logs (structured JSON)

> **What you get:** All six services emit structured JSON logs. The Datadog
> Agent picks them up automatically — no code change needed. Validate that logs
> appear in [Log Explorer](https://app.datadoghq.com/logs) filtered by
> `kube_namespace:finance` (EKS) or `service:gateway-api` (Docker).

All services already log in structured JSON format using their native library:

| Service | Library | Format |
|---|---|---|
| `gateway-api` | `python-json-logger` | JSON with `timestamp`, `level`, `message` |
| `fraud-detection` | `python-json-logger` | Same as above |
| `account-service` | Logback + `logstash-logback-encoder` | JSON with Spring context |
| `batch-processor` | Logback + `logstash-logback-encoder` | JSON with Spring Batch context |
| `transaction-service` | `pino` | JSON with `time`, `level`, `msg` |
| `notification-service` | `log/slog` (stdlib) | JSON with `time`, `level`, `msg` |

**Nothing to uncomment for this step.** If logs are not appearing:

- **Docker:** check the Agent label on each container in `deploy/docker/docker-compose.datadog.yml`:
  ```yaml
  labels:
    com.datadoghq.ad.logs: '[{"source":"python","service":"gateway-api"}]'
  ```
  Uncomment the `com.datadoghq.ad.logs` label block in each service.

- **EKS:** the Datadog Agent collects all container logs automatically via
  `containerCollectAll: true`. Go to
  [Logs > Configuration > Indexes](https://app.datadoghq.com/logs/pipelines/indexes)
  and move the `finance-app` index to the top of the list.

---

## Step 2 — Unified Service Tags

> **What you get:** Every piece of telemetry (traces, logs, metrics, profiles)
> carries `env`, `service`, and `version` tags. This enables correlation across
> all Datadog products.

These tags are already wired in `deploy/docker/docker-compose.datadog.yml` and
`deploy/kubernetes/base/01-config.yaml` — no code changes needed.

Verify they appear on your logs and metrics:

```
env:staging  service:gateway-api  version:1.0.0
```

To change the environment, edit `DD_ENV` in:
- **Docker:** `deploy/docker/.env` (copy from `deploy/docker/.env.example`)
- **EKS:** `deploy/kubernetes/base/01-config.yaml` → `DD_ENV` key in the
  `app-config` ConfigMap, then `make deploy-k8s-eks`

---

## Step 3 — APM traces

> **What you get:** Distributed traces across all services. The APM Service
> Map shows the full call graph: gateway-api → account-service →
> transaction-service → fraud-detection → notification-service.

### gateway-api (Python / FastAPI)

**File:** `gateway-api/main.py`

Uncomment the APM block near the top of the file:

```python
# ── DATADOG INSTRUMENTATION ───────────────────────────────────────────────
from ddtrace import patch_all, tracer
from ddtrace.contrib.logging import patch as patch_logging
patch_all()
patch_logging()
```

`patch_all()` auto-instruments FastAPI, `httpx`, `redis`, and all other
supported libraries. `patch_logging()` injects `dd.trace_id` and `dd.span_id`
into every log line (required for Step 4).

### fraud-detection (Python)

**File:** `fraud-detection/main.py`

Uncomment the identical block at the top:

```python
from ddtrace import patch_all
from ddtrace.contrib.logging import patch as patch_logging
patch_all()
patch_logging()
```

### account-service (Java / Spring Boot)

**File:** `deploy/docker/docker-compose.datadog.yml` (Docker)  
**File:** `deploy/kubernetes/base/services/account-service.yaml` (EKS)

The Java agent instruments Spring MVC, JDBC, JMS, and Logback automatically.
No code changes needed — only a JVM flag.

**Docker** — uncomment in `docker-compose.datadog.yml`:
```yaml
environment:
  JAVA_TOOL_OPTIONS: >-
    -javaagent:/dd-java-agent.jar
    -Ddd.service=account-service
    -Ddd.env=${DD_ENV:-staging}
    -Ddd.version=${DD_VERSION:-1.0.0}
    -Ddd.logs.injection=true
    -Ddd.profiling.enabled=false
    -Ddd.data.jobs.enabled=false
```

**EKS** — add to the `account-service` Deployment env in
`deploy/kubernetes/base/services/account-service.yaml`:
```yaml
- name: JAVA_TOOL_OPTIONS
  value: >-
    -javaagent:/dd-java-agent.jar
    -Ddd.service=account-service
    -Ddd.env=$(DD_ENV)
    -Ddd.version=$(DD_VERSION)
    -Ddd.logs.injection=true
```
The `dd-java-agent.jar` is already included in the Docker image (see
`account-service/Dockerfile`).

### batch-processor (Java / Spring Batch)

Same pattern as `account-service`. Also uncomment the
`DatadogJobListener` bean in
`batch-processor/src/main/java/com/example/finance/batchprocessor/DatadogJobListener.java`
to tag each job run with `job.name`, `job.status`, and `job.records_processed`.

```yaml
# docker-compose.datadog.yml
JAVA_TOOL_OPTIONS: >-
  -javaagent:/dd-java-agent.jar
  -Ddd.service=batch-processor
  -Ddd.env=${DD_ENV:-staging}
  -Ddd.version=${DD_VERSION:-1.0.0}
  -Ddd.logs.injection=true
  -Ddd.data.jobs.enabled=true
```

### transaction-service (Node.js / Express)

**File:** `transaction-service/src/index.js`

The `dd-trace` require **must be the very first line** — before any other import.
Uncomment at the top of the file:

```js
const tracer = require('dd-trace').init({
  service:  process.env.DD_SERVICE  || 'transaction-service',
  env:      process.env.DD_ENV,
  version:  process.env.DD_VERSION,
  hostname: process.env.DD_AGENT_HOST || 'datadog-agent',
});
```

### notification-service (Go)

**File:** `notification-service/main.go`

Uncomment the tracer import and start/stop calls:

```go
import (
    "gopkg.in/DataDog/dd-trace-go.v1/ddtrace/tracer"
)

func main() {
    tracer.Start(
        tracer.WithServiceName("notification-service"),
        tracer.WithEnv(os.Getenv("DD_ENV")),
        tracer.WithServiceVersion(os.Getenv("DD_VERSION")),
        tracer.WithAgentAddr(os.Getenv("DD_AGENT_HOST") + ":8126"),
        tracer.WithRuntimeMetrics(),
    )
    defer tracer.Stop()
    // ...
}
```

**Validate:** After redeploying, open
[APM > Services](https://app.datadoghq.com/apm/services) and check that all
six services appear. Click any service to see the Service Map showing the full
call graph.

---

## Step 4 — Log–Trace correlation

> **What you get:** A "View Trace" button appears on every log line. Click any
> log in Log Explorer to jump directly to the APM trace that produced it.

Requires Step 3 to be complete.

### Python services (gateway-api, fraud-detection)

`patch_logging()` (already uncommented in Step 3) injects `dd.trace_id` and
`dd.span_id` into every log record. Nothing more to do.

Verify by checking a log entry — it should contain:
```json
{
  "dd.trace_id": "1234567890123456789",
  "dd.span_id":  "9876543210987654321",
  "dd.service":  "gateway-api",
  "dd.env":      "staging"
}
```

### Java services (account-service, batch-processor)

`-Ddd.logs.injection=true` (set in Step 3) injects the trace context into
Logback's MDC automatically. The Logback JSON encoder picks it up with no
further changes.

### Node.js (transaction-service)

Uncomment `logInjection: true` in the tracer init:

```js
const tracer = require('dd-trace').init({
  // ... existing options
  logInjection: true,   // ← uncomment this line
});
```

`pino` will automatically include `dd.trace_id` and `dd.span_id` in every log.

### Go (notification-service)

`log/slog` with the JSON handler inherits trace context automatically when
spans are active on the same goroutine. No additional setup needed.

**Validate:** In [Log Explorer](https://app.datadoghq.com/logs), open any log
from a traced request. You should see a **"View Trace"** button in the
right-hand panel.

---

## Step 5 — Custom spans for business operations

> **What you get:** Fine-grained spans for the most important Finance
> operations: `payment.authorize`, `fraud.score`, `ledger.commit`,
> `alert.send`. These appear as child spans inside the service's trace.

The custom span code is already written and commented out in each service.
Uncomment the relevant blocks:

### gateway-api — `payment.authorize` span

**File:** `gateway-api/main.py`, function `initiate_payment()`

```python
with tracer.trace("payment.authorize", service="gateway-api", resource="POST /v1/payments") as span:
    span.set_tag("transaction.type", payload.get("transaction_type", "payment"))
    span.set_tag("payment.currency",  payload.get("currency", "EUR"))
    span.set_tag("account.tier",      account_tier)
    # ⚠ High cardinality — never tag with raw payment_id or user email
    # ... business logic here
```

### transaction-service — `ledger.commit` span

**File:** `transaction-service/src/services/ledger.js`

```js
const span = tracer.startSpan('ledger.commit', {
  tags: {
    'transaction.type': txType,
    'payment.currency': currency,
    'db.instance':      'postgres-ledger',
  },
});
// ... ledger write
span.finish();
```

### fraud-detection — `fraud.score` span

**File:** `fraud-detection/main.py` (or `listener.py`)

```python
with tracer.trace("fraud.score", service="fraud-detection") as span:
    span.set_tag("fraud.score_bucket", score_bucket)   # "low"|"medium"|"high"
    span.set_tag("messaging.destination", "fraud.score.queue")
    # ⚠ Do not tag with raw fraud score float — bucket it first
```

### notification-service — `alert.send` span

**File:** `notification-service/main.go`, function `sendNotification()`

```go
span, ctx := tracer.StartSpanFromContext(ctx, "alert.send",
    tracer.Tag("notification.channel",    channel),
    tracer.Tag("notification.event_type", eventType),
    tracer.Tag("messaging.destination",   "alert.queue"),
)
defer span.Finish()
```

> ⚠ **Cardinality warning:** Never tag spans with unbounded values such as
> `payment.id`, `user.id`, raw amounts, or full URLs. Use normalised,
> bounded tag values (`account.tier: premium`, `fraud.score_bucket: high`).
> See: https://docs.datadoghq.com/tagging/assigning_tags/#defining-tags

---

## Step 6 — Custom metrics (DogStatsD)

> **What you get:** Finance-domain metrics in the Metrics Explorer and
> dashboards: `finance.payment.initiated`, `finance.payment.processing_time`,
> `finance.fraud.score`, `finance.batch.records_processed`.

### gateway-api (Python)

**File:** `gateway-api/main.py`, near the top

```python
from datadog import initialize, statsd
initialize(statsd_host=os.getenv("DD_AGENT_HOST", "datadog-agent"), statsd_port=8125)
```

Then in `initiate_payment()`:

```python
statsd.increment("finance.payment.initiated",
    tags=[f"currency:{currency}", f"env:{DD_ENV}"])
statsd.histogram("finance.payment.processing_time", elapsed_ms,
    tags=[f"currency:{currency}", f"status:{status}", f"env:{DD_ENV}"])
```

### transaction-service (Node.js)

**File:** `transaction-service/src/index.js`

Uncomment `runtimeMetrics: true` in the tracer init — this also enables the
DogStatsD socket:

```js
const tracer = require('dd-trace').init({
  // ...
  runtimeMetrics: true,  // ← uncomment
});
```

Then in payment routes, uncomment the `statsd.increment` / `statsd.histogram`
calls.

### batch-processor (Java)

**File:** `batch-processor/src/main/java/.../DatadogJobListener.java`

Uncomment the `statsd.incrementCounter` call in `afterJob()`:

```java
statsd.incrementCounter("finance.batch.records_processed",
    "job.name:" + jobName,
    "job.status:" + status,
    "env:" + System.getenv("DD_ENV"));
```

### notification-service (Go)

**File:** `notification-service/main.go`

```go
statsdClient.Histogram("finance.notification.dispatch_time", elapsedMs,
    []string{"channel:" + channel, "env:" + os.Getenv("DD_ENV")}, 1)
statsdClient.Incr("finance.notification.sent",
    []string{"channel:" + channel, "event_type:" + eventType}, 1)
```

**Validate:** Open
[Metrics Explorer](https://app.datadoghq.com/metric/explorer) and search for
`finance.*`. You should see all custom metrics appearing within ~30 seconds of
sending traffic.

---

## Step 7 — Continuous Profiler

> **What you get:** CPU flame graphs and memory profiles for each service,
> correlated with slow traces. Useful for identifying hot loops, memory leaks,
> and inefficient database queries in the Finance batch jobs.

### Python services (gateway-api, fraud-detection)

**File:** `gateway-api/main.py` and `fraud-detection/main.py`

This import must be the **very first line** in the file — before everything
else including `patch_all()`:

```python
import ddtrace.profiling.auto  # noqa: F401
```

### Java services (account-service, batch-processor)

Add `-Ddd.profiling.enabled=true` to `JAVA_TOOL_OPTIONS`:

```yaml
JAVA_TOOL_OPTIONS: >-
  -javaagent:/dd-java-agent.jar
  -Ddd.profiling.enabled=true   # ← add this
  -Ddd.logs.injection=true
  # ...
```

### Node.js (transaction-service)

Uncomment `profiling: true` in the tracer init:

```js
const tracer = require('dd-trace').init({
  // ...
  profiling: true,  // ← uncomment
});
```

### Go (notification-service)

**File:** `notification-service/main.go`

Uncomment the profiler import and start call:

```go
import "gopkg.in/DataDog/dd-trace-go.v1/profiler"

profiler.Start(
    profiler.WithService("notification-service"),
    profiler.WithEnv(os.Getenv("DD_ENV")),
    profiler.WithProfileTypes(
        profiler.CPUProfile,
        profiler.HeapProfile,
        profiler.GoroutineProfile,
    ),
)
defer profiler.Stop()
```

**Validate:** Open
[Continuous Profiler](https://app.datadoghq.com/profiling) and select any
service. Run `make test-traffic` to generate load and trigger profiling data.

---

## Step 8 — Data Streams Monitoring (DSM)

> **What you get:** End-to-end pipeline visibility for the JMS / ActiveMQ
> Artemis queues: `fraud.score.queue` and `alert.queue`. See consumer lag,
> end-to-end latency, and throughput for each queue.

DSM requires `DD_DATA_STREAMS_ENABLED=true` — already set in
`docker-compose.datadog.yml` and `deploy/kubernetes/overlays/eks-datadog/`.

### account-service / transaction-service — JMS producer checkpoint

**File:**
`account-service/src/main/java/.../PaymentEventProducer.java`

Uncomment the producer checkpoint before sending each JMS message:

```java
// import datadog.trace.api.experimental.DataStreamsCheckpointer;

DataStreamsCheckpointer.get().setProducerCheckpoint(
    message,                           // javax.jms.Message
    "jms",                             // type
    destination.getQueueName()         // queue name
);
```

### fraud-detection — JMS consumer checkpoint

**File:** `fraud-detection/listener.py`

Uncomment the consume checkpoint at the top of the message handler:

```python
# from ddtrace.data_streams import set_consume_checkpoint

def on_message(frame):
    set_consume_checkpoint("jms", "fraud.score.queue", frame.headers)
    # ... fraud scoring logic
```

**Validate:** Open
[Data Streams > Pipelines](https://app.datadoghq.com/data-streams). You should
see the `fraud.score.queue` and `alert.queue` pipeline map. Run
`make test-traffic` to generate JMS messages.

---

## Step 9 — Data Jobs Monitoring (batch-processor)

> **What you get:** Job run history, step durations, record throughput, and
> failure correlation with APM traces for the nightly reconciliation and
> statement generation jobs.

Requires `JAVA_TOOL_OPTIONS` to include `-Ddd.data.jobs.enabled=true` (Step 3).

**File:**
`batch-processor/src/main/java/.../DatadogJobListener.java`

Uncomment the full `@Bean` definition to register the listener:

```java
@Bean
public JobExecutionListener datadogJobListener() {
    return new DatadogJobListener();
}
```

The listener already tags each run with `job.name`, `job.status`,
`job.records_processed`, `job.read_count`, and `job.skip_count`.

**Validate:** Open [Data Jobs](https://app.datadoghq.com/data-jobs) and
trigger a batch run. Each step's duration and record count should appear within
a few seconds of the job completing.

---

## Quick reference

| Step | Signal | Services affected | Key flag / import |
|---|---|---|---|
| 1 | Logs (JSON) | All | Already active — no change needed |
| 2 | Unified Service Tags | All | Already active via env vars |
| 3 | APM traces | All | `patch_all()` / `dd-trace` require / `-javaagent` |
| 4 | Log–trace correlation | All | `patch_logging()` / `logInjection:true` / `-Ddd.logs.injection=true` |
| 5 | Custom spans | gateway-api, transaction-service, fraud-detection, notification-service | `tracer.trace()` / `tracer.startSpan()` |
| 6 | Custom metrics | gateway-api, transaction-service, batch-processor, notification-service | `statsd.increment()` / `statsd.histogram()` |
| 7 | Continuous Profiler | All | `ddtrace.profiling.auto` / `-Ddd.profiling.enabled=true` / `profiler.Start()` |
| 8 | Data Streams (DSM) | account-service, transaction-service, fraud-detection | `setProducerCheckpoint` / `set_consume_checkpoint` |
| 9 | Data Jobs | batch-processor | `-Ddd.data.jobs.enabled=true` + `DatadogJobListener` |

---

## Key references

| Topic | URL |
|---|---|
| APM setup | https://docs.datadoghq.com/tracing/trace_collection/ |
| Log correlation | https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/ |
| Custom metrics (DogStatsD) | https://docs.datadoghq.com/developers/dogstatsd/ |
| Continuous Profiler | https://docs.datadoghq.com/profiler/ |
| Data Streams Monitoring | https://docs.datadoghq.com/data_streams/ |
| Data Jobs Monitoring | https://docs.datadoghq.com/data_jobs/ |
| Unified Service Tagging | https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/ |
| Tagging best practices | https://docs.datadoghq.com/tagging/assigning_tags/ |
