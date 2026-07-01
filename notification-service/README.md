# notification-service

Go 1.22 microservice that consumes alert messages from `alert.queue` (ActiveMQ Artemis via STOMP)
and dispatches email/SMS notifications. Part of the Finance sample application.

**Technology stack:** Go 1.22, `go-stomp/stomp`, `log/slog` (stdlib structured JSON logging)

---

## Datadog Instrumentation Notes

All Datadog instrumentation code ships **commented out**. The service runs cleanly with zero
Datadog configuration. Follow the steps below to progressively enable each observability layer.

> **Go and Orchestrion:** Go services use [Orchestrion](https://docs.datadoghq.com/tracing/trace_collection/automatic_instrumentation/dd_libraries/go/)
> for compile-time automatic instrumentation — the preferred approach over manual `tracer.Start()` calls.
> Orchestrion rewrites the binary at build time to inject APM spans without requiring import changes.
> See Step 3 for details.

---

## Learning Progression

### Step 1 — Enable the Datadog Agent

Deploy the Datadog Agent via the Datadog Operator. Add the admission controller annotation to the pod spec:
```yaml
annotations:
  admission.datadoghq.com/enabled: "true"
```
Reference: https://docs.datadoghq.com/containers/kubernetes/

Set your API key (never hardcode — use a K8s Secret or Secrets Manager):
```bash
DD_API_KEY=<your-api-key>
```

### Step 2 — Set Unified Service Tags

Copy `.env.example` to `.env` and populate the three required tags:
```dotenv
DD_ENV=staging
DD_SERVICE=notification-service
DD_VERSION=1.0.0
DD_AGENT_HOST=datadog-agent
```

These tags propagate to all telemetry (traces, logs, metrics, profiles). Without them, signals
cannot be correlated across the Finance service mesh.
Reference: https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/

### Step 3 — Enable APM Tracing

**Option A — Orchestrion (recommended):** No code changes required. Orchestrion instruments the
binary at compile time by rewriting the AST.

```bash
# Install once
go install github.com/DataDog/orchestrion@latest

# Build with auto-instrumentation
orchestrion go build ./...
```

The `Dockerfile` includes a commented-out alternative `RUN` step that uses Orchestrion. Swap it in
and rebuild the image.

**Option B — Manual tracer:** Uncomment the `tracer.Start()` / `defer tracer.Stop()` block in
`main.go` and add the dependency:
```bash
go get go.datadoghq.com/dd-trace-go/v2/ddtrace/tracer
go mod tidy
```

Verify: navigate to **APM > Services** in Datadog — `notification-service` should appear within
60 seconds of the first message being processed.
Reference: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/go/

### Step 4 — Enable Log Correlation

Set `DD_LOGS_INJECTION=true`. The tracer automatically injects `dd.trace_id` and `dd.span_id`
into every `slog` JSON log line. This creates a clickable link from a log line in Log Management
directly to the corresponding APM trace.

Verify: in **Log Management**, filter by `service:notification-service` and confirm `dd.trace_id`
appears in log attributes.
Reference: https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/go/

### Step 5 — Uncomment the Custom `alert.send` Span

In `main.go`, find the `// ── DATADOG INSTRUMENTATION — custom span: alert.send ──` block inside
`sendNotification()` and uncomment it. This creates a child span under the JMS consumer span,
tagged with:
- `notification.channel` (email / sms)
- `notification.event_type` (fraud_detected, payment_failed, etc.)
- `jms.correlation_id` — the business-level key linking the async producer → consumer chain
- `messaging.destination` — the queue name (`alert.queue`)

Verify: in **APM > Traces**, expand a `jms.consume` trace — you should see `alert.send` as a
child span with the Finance domain tags.
Reference: https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/go/

### Step 6 — Enable DogStatsD Custom Metrics

Add the DogStatsD client dependency:
```bash
go get github.com/DataDog/datadog-go/v5/statsd
```

Uncomment the `statsdClient.Histogram` and `statsdClient.Incr` blocks in `sendNotification()`.
This emits:
- `finance.notification.dispatch_time` — histogram of dispatch latency, tagged by channel and event type
- `finance.notification.sent` — counter of notifications sent

Verify: in **Metrics Explorer**, search for `finance.notification.*`.
Reference: https://docs.datadoghq.com/developers/dogstatsd/

### Step 7 — Enable the Continuous Profiler

Add the profiler dependency:
```bash
go get gopkg.in/DataDog/dd-trace-go.v1/profiler
```

Uncomment the `profiler.Start()` / `defer profiler.Stop()` block in `main.go`. The profiler
captures CPU, heap, goroutine, and mutex profiles every 60 seconds.

Verify: in **Continuous Profiler**, select `service:notification-service` — flame graphs should
appear. Correlate CPU spikes with slow `alert.send` traces by clicking "View Trace" from a
flame graph call stack.
Reference: https://docs.datadoghq.com/profiler/enabling/go/

### Step 8 — Enable Data Streams Monitoring (DSM)

Set `DD_DATA_STREAMS_ENABLED=true` in your environment.

Add the DSM dependency:
```bash
go get go.datadoghq.com/dd-trace-go/v2/datastreams
```

Uncomment the `datastreams.SetConsumerCheckpoint(...)` block in `processMessage()`. This records
the consumer lag and end-to-end latency for the `payment → fraud → alert.queue → notification`
pipeline.

DSM producer checkpoints must also be set in `transaction-service` (Node.js) and
`account-service` (Java) for the full pathway to appear.

Verify: in **Data Streams > Pathways**, the `alert.queue` node should appear with consumer lag
and end-to-end latency metrics.
Reference: https://docs.datadoghq.com/data_streams/go/

### Step 9 — Configure Database Monitoring (DBM)

`notification-service` does not directly query PostgreSQL. DBM is configured on the Agent for
`postgres-ledger` — see `account-service/README.md` Step 9 and
`deploy/kubernetes/datadog/checks/postgres-check.yaml` for the Agent `postgres.d/conf.yaml` config.

### Step 10 — Add ActiveMQ Broker Metrics

The Datadog Agent's ActiveMQ integration collects queue depth, consumer count, and memory usage
from the Artemis broker via JMX. See `deploy/kubernetes/datadog/checks/` for the
`activemq.d/conf.yaml` Agent configuration.

This gives you `finance.jms.queue.depth` for `alert.queue` — useful for alerting on notification
backlogs during high-fraud periods.
Reference: https://docs.datadoghq.com/integrations/activemq/

### Step 11 — Enable Runtime Metrics

Set `DD_RUNTIME_METRICS_ENABLED=true`. Go runtime metrics (goroutine count, heap allocation,
GC pause time) appear in **APM > Services > notification-service > Runtime Metrics**.

These metrics help diagnose goroutine leaks if the STOMP subscription channel backs up.
Reference: https://docs.datadoghq.com/tracing/metrics/runtime_metrics/go/

### Step 12 — Add Synthetic Monitoring

Create API tests in `synthetics/` for the health and payment endpoints. While
`notification-service` is async and has no HTTP endpoint of its own, the Synthetic test on
`POST /v1/payments` in `gateway-api` triggers the full async chain — including the
`alert.queue` consumer — and the resulting trace will include the `notification-service` span.

Reference: https://docs.datadoghq.com/synthetics/

---

## Span Tags Reference

| Tag | Example value | Rationale |
|---|---|---|
| `notification.channel` | `email`, `sms` | Slice error rates and latency by channel |
| `notification.event_type` | `fraud_detected`, `payment_failed` | Alert on specific event type failure rates |
| `jms.correlation_id` | `txn-8f3a2c` | Business-level correlation across async hops |
| `messaging.destination` | `alert.queue` | Identify which JMS queue this consumer reads from |
| `account.id` | `acc-001` | Safe to tag — opaque ID, no PII |

> **PII warning:** Never tag or log raw account numbers, IBANs, card numbers, balances, or
> personal details. Tag with opaque IDs only and resolve PII in the service layer.
> Reference: https://docs.datadoghq.com/tracing/configure_data_security/

---

## Key References

| Topic | URL |
|---|---|
| Unified Service Tagging | https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/ |
| APM — Go | https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/go/ |
| Orchestrion (auto-instrumentation) | https://docs.datadoghq.com/tracing/trace_collection/automatic_instrumentation/dd_libraries/go/ |
| Custom instrumentation — Go | https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/go/ |
| Log correlation — Go | https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/go/ |
| DogStatsD — Go | https://docs.datadoghq.com/developers/dogstatsd/?tab=go |
| Continuous Profiler — Go | https://docs.datadoghq.com/profiler/enabling/go/ |
| Data Streams Monitoring — Go | https://docs.datadoghq.com/data_streams/go/ |
| ActiveMQ integration | https://docs.datadoghq.com/integrations/activemq/ |
| Runtime metrics — Go | https://docs.datadoghq.com/tracing/metrics/runtime_metrics/go/ |
| Tagging best practices | https://docs.datadoghq.com/tagging/assigning_tags/ |
| Cardinality guidance | https://docs.datadoghq.com/tagging/assigning_tags/#defining-tags |
