# transaction-service

Node.js 20 / Express microservice for the Finance sample application.
Handles payment initiation, ledger writes (PostgreSQL stub), and
fraud-scoring event production to ActiveMQ Artemis via STOMP.

The service runs cleanly with no Datadog configuration. Every
instrumentation block is commented out and labelled — work through
the Learning Progression below to enable each layer one at a time.

---

## Datadog Instrumentation Notes

> **Critical:** `dd-trace` must be `require()`d before any other module.
> It patches Node.js core modules (`http`, `net`, `dns`) at load time.
> Requiring it after `express` or `pino` will produce incomplete or
> missing traces for inbound HTTP requests and outbound STOMP connections.
> The safest approach is the `--require dd-trace/init` Node flag in the
> Dockerfile CMD (see Step 3 below) so the entrypoint file never needs
> to change.

---

## Learning Progression

### Step 1 — Enable the Datadog Agent

Start the Datadog Agent alongside this service.

**Docker Compose:** See `deploy/docker/docker-compose.yml`. The Agent
container is already defined; set `DD_API_KEY` in your shell and run:

```bash
export DD_API_KEY=<your-api-key>
docker compose up
```

**Kubernetes:** Apply the `DatadogAgent` CRD from `deploy/kubernetes/`.
The Admission Controller will inject the Agent sidecar automatically.

Verify the Agent is running and can reach Datadog:

```bash
docker exec -it datadog-agent agent status
```

Reference: https://docs.datadoghq.com/containers/docker/

---

### Step 2 — Set Unified Service Tags

Copy `.env.example` to `.env` and set the three mandatory tags:

```dotenv
DD_ENV=staging
DD_SERVICE=transaction-service
DD_VERSION=1.0.0
DD_AGENT_HOST=datadog-agent
```

These tags propagate to every telemetry signal — traces, logs, metrics,
and RUM — and power the correlation links in the Datadog UI (Deployment
Tracking, Service Catalog SLOs, "View in APM" from a log line).

In CI, automate the version: `DD_VERSION=$(git rev-parse --short HEAD)`

Reference: https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/

---

### Step 3 — Enable APM Tracing

1. Install `dd-trace`:

   ```bash
   npm install dd-trace --save
   ```

2. Uncomment the tracer initialisation block at the **top** of
   `src/index.js` (before any other `require`).

   Alternatively, use the `--require` flag in the Dockerfile CMD so
   source code is not modified:

   ```dockerfile
   CMD ["node", "--require", "dd-trace/init", "src/index.js"]
   ```

3. Rebuild and restart the service, then trigger a payment:

   ```bash
   curl -X POST http://localhost:8082/v1/payments \
     -H 'Content-Type: application/json' \
     -d '{"amount":100,"currency":"EUR","account_id":"acc-001"}'
   ```

4. Open **APM > Services** in Datadog and verify `transaction-service`
   appears with `payment.authorize` and `ledger.commit` spans.

Reference: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/nodejs/

---

### Step 4 — Enable Log Correlation

1. Set `logInjection: true` inside the `tracer.init({...})` call in
   `src/index.js`, **or** set `DD_LOGS_INJECTION=true` in the
   environment (equivalent effect).

2. Restart the service and send a payment. Each pino log line now
   contains `dd.trace_id` and `dd.span_id` fields.

3. In **Log Management**, open any log from this service and click
   **View in APM** — you will jump directly to the correlated trace.

Reference: https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/nodejs/

---

### Step 5 — Uncomment Custom Spans

Search for `// ── DATADOG INSTRUMENTATION` blocks in:

- `src/routes/payments.js` — `payment.authorize` span with
  `transaction.type` and `payment.currency` tags
- `src/services/ledger.js` — `ledger.commit` span with `db.instance`
  tag (enables the "View in DBM" button)

Uncomment the `tracer.startSpan(...)` and `span.finish()` calls.
Restart and verify the spans appear nested in the flame graph.

Finance span tags to apply:

| Tag | Example | Rationale |
|---|---|---|
| `transaction.type` | `payment` | Slice error rates by category |
| `payment.currency` | `EUR` | Regional / regulatory analysis |
| `http.route` | `/v1/payments` | Normalised route (not raw URL) |
| `db.instance` | `postgres-ledger` | DBM correlation |
| `messaging.destination` | `fraud.score.queue` | DSM queue identification |

> **HIGH-CARDINALITY WARNING:** Do not use `payment_id`, `account_id`,
> or raw `messaging.message_id` as DogStatsD metric tags — their value
> spaces are unbounded. Use them on spans and log records only, where
> trace sampling already limits volume.
> https://docs.datadoghq.com/tagging/assigning_tags/#defining-tags

Reference: https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/nodejs/

---

### Step 6 — Uncomment DogStatsD Custom Metrics

1. Install `hot-shots` (Datadog's recommended Node.js DogStatsD client):

   ```bash
   npm install hot-shots --save
   ```

2. Uncomment the `StatsD` client block in `src/routes/payments.js` and
   the metric calls in `src/routes/payments.js` and `src/services/ledger.js`.

3. Set `DD_RUNTIME_METRICS_ENABLED=true` in `.env` to also emit
   built-in Node.js V8 / GC / event-loop metrics automatically.

Metrics emitted by this service:

| Metric | Type | Tags | Purpose |
|---|---|---|---|
| `finance.payment.initiated` | counter | `transaction.type`, `payment.currency` | Volume tracking, alert on drops |
| `finance.payment.processing_time` | histogram | `transaction.type`, `payment.currency` | P99 latency alerting |
| `finance.ledger.commit.errors` | counter | `db.instance`, `payment.currency` | DB write failure rate |

Reference: https://docs.datadoghq.com/developers/dogstatsd/

---

### Step 7 — Enable Continuous Profiler

Set `profiling: true` in the `tracer.init({...})` call (already in the
commented block in `src/index.js`), or set:

```dotenv
DD_PROFILING_ENABLED=true
```

Open **APM > Profiling** in Datadog. Filter by `service:transaction-service`
and correlate CPU flame graphs with slow `payment.authorize` traces to
identify hot code paths (e.g. JSON serialisation, STOMP header construction).

Reference: https://docs.datadoghq.com/profiler/enabling/nodejs/

---

### Step 8 — Add RUM to the Frontend Stub

See `frontend-stub/` at the repository root. Uncomment the Browser SDK
snippet in `frontend-stub/index.html`.

Finance-specific RUM actions to instrument:
- `payment_form.submit` — track conversion funnel drop-off
- `account_dashboard.load` — measure Time to Interactive for premium users

Enable Session Replay with privacy mode to protect financial data:

```javascript
// defaultPrivacyLevel: 'mask-user-input'  // masks card numbers, IBANs
```

Reference: https://docs.datadoghq.com/real_user_monitoring/browser/

---

### Step 9 — Configure Database Monitoring (DBM) for PostgreSQL

DBM is an Agent-side feature — this service requires no code changes.

1. Run the PostgreSQL prerequisites in
   `deploy/docker/datadog-agent/conf.d/postgres.d/setup.sql`
   (creates the `datadog` monitoring user, enables `pg_stat_statements`).

2. Mount the Agent config from
   `deploy/docker/datadog-agent/conf.d/postgres.d/conf.yaml`.

3. In any `ledger.commit` span, click **View in DBM** to see the query
   plan and wait events for that exact request.

   This link works because `dd-trace` automatically sets `db.instance`
   and `peer.hostname` on database spans to match the DBM Agent config.

Reference: https://docs.datadoghq.com/database_monitoring/connect_dbm_and_apm/

---

### Step 10 — Enable Data Streams Monitoring (DSM)

Set `DD_DATA_STREAMS_ENABLED=true` in `.env`.

`dd-trace` auto-instruments STOMP connections and injects DSM pathway
context into STOMP message headers. No code changes are required beyond
the environment variable.

Verify in **APM > Data Streams**:
- The `transaction-service → fraud.score.queue → fraud-detection` pathway
  appears on the pipeline map.
- Consumer lag on `fraud.score.queue` is visible — alert when it exceeds
  your fraud-scoring SLA (e.g. > 30 s means payments are queued without
  fraud checks).

See `src/messaging/producer.js` for the manual checkpoint fallback if
you switch to a custom STOMP client that does not carry headers.

Reference: https://docs.datadoghq.com/data_streams/nodejs/

---

### Step 11 — Enable Data Jobs Monitoring

This step applies to the `batch-processor` service (Spring Batch), not
to `transaction-service`. See `batch-processor/README.md`.

The `transaction-service` is the upstream producer that feeds data into
the batch reconciliation pipeline. Use DSM (Step 10) to observe the
handoff between this service and the batch processor.

Reference: https://docs.datadoghq.com/data_jobs/java/

---

### Step 12 — Add Synthetic API Tests

See `synthetics/` at the repository root for pre-built test definitions:

- `synthetics/health-check.json` — `GET /health` on all services
- `synthetics/payment-flow.json` — `POST /v1/payments` happy-path flow

Import them via the Datadog API or Terraform (`datadog_synthetics_test`
resource). Each test automatically generates a Synthetic trace that
appears in APM alongside your real traffic — use this to validate
instrumentation in staging before enabling production monitors.

Reference: https://docs.datadoghq.com/synthetics/

---

## Local Development

```bash
cp .env.example .env
# Edit .env — set ACTIVEMQ_URL and POSTGRES_URL for your local broker/DB
npm install
npm run dev        # nodemon — reloads on file changes
```

Send a test payment:

```bash
curl -X POST http://localhost:8082/v1/payments \
  -H 'Content-Type: application/json' \
  -d '{"amount":250.00,"currency":"EUR","account_id":"acc-042"}'
```

Retrieve it:

```bash
curl http://localhost:8082/v1/payments/<payment_id from response>
```

Health check:

```bash
curl http://localhost:8082/health
```

---

## Environment Variables

See `.env.example` for the full reference with inline explanations.

| Variable | Default | Description |
|---|---|---|
| `DD_ENV` | `development` | Unified Service Tag — environment |
| `DD_SERVICE` | `transaction-service` | Unified Service Tag — service name |
| `DD_VERSION` | `0.0.0` | Unified Service Tag — version / image tag |
| `DD_AGENT_HOST` | `datadog-agent` | Datadog Agent hostname |
| `PORT` | `8082` | HTTP listen port |
| `ACTIVEMQ_URL` | `stomp://localhost:61613` | Broker STOMP endpoint |
| `POSTGRES_URL` | — | PostgreSQL connection string |
| `LOG_LEVEL` | `info` | pino log level |
