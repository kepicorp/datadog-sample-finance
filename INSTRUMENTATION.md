# Finance Sample App — Instrumentation Guide

This guide explains how to enable full Datadog observability on the finance
sample app using the `make instrument` / `make uninstrument` commands.

The app ships with **all Datadog instrumentation commented out** — it runs
cleanly with zero Datadog configuration. `make instrument` uncomments every
instrumentation block across all six services in one shot. `make uninstrument`
reverses it, restoring the original commented state.

---

## TL;DR — Full instrumentation in four commands

```bash
# 1. Apply all instrumentation patches
make instrument

# 2. Rebuild images with the instrumented code
make build           # local Docker
# make build-ecr     # EKS (cross-compiles for linux/amd64)

# 3. Restart the stack
make down-dd && make up-dd     # local Docker
# make deploy-k8s-eks          # EKS

# 4. Generate traffic and validate in Datadog
python3 scripts/generate-traffic.py --rate 3 --duration 60
```

To reverse everything:

```bash
make uninstrument
make build && make down-dd && make up-dd
```

---

## Prerequisites

Before `make instrument` is useful, the following must be in place.

### Datadog API key

```bash
# Docker — set in deploy/docker/.env
DD_API_KEY=<your-key>          # https://app.datadoghq.com/organization-settings/api-keys

# EKS — stored in AWS Secrets Manager (created by make tf-apply-aws)
aws secretsmanager put-secret-value \
  --secret-id finance-app/staging/dd-api-key \
  --secret-string "<your-key>" \
  --profile <profile> --region <region>
```

### Datadog Agent

```bash
make up-dd           # Docker (starts datadog/agent:7-jmx)
make deploy-k8s-dd   # EKS
```

> **Important — use the `-jmx` agent image for Docker.**
> `deploy/docker/docker-compose.datadog.yml` uses `datadog/agent:7-jmx`.
> The standard `datadog/agent:7` image has no JRE and cannot run the
> ActiveMQ JMX check.

---

## What `make instrument` does

`make instrument` applies unified diff patches to five services in one
command. `make uninstrument` reverses all patches cleanly.

| Service | Language | What gets patched |
|---|---|---|
| `gateway-api` | Python/FastAPI | `main.py` — APM init, log correlation, custom spans, DogStatsD metrics; `requirements.txt` — adds `ddtrace`, `datadog` |
| `fraud-detection` | Python | `main.py` — APM init, log correlation, custom `fraud.score` span; `requirements.txt` — adds `ddtrace[data_streams]` |
| `transaction-service` | Node.js | `src/index.js` — `dd-trace` init with log injection and runtime metrics; `package.json` — adds `dd-trace` |
| `notification-service` | Go | `main.go` — tracer/profiler init, `alert.send` span; `go.mod` — adds `dd-trace-go/v2` + `datadog-go/v5` |
| `batch-processor` | Java/Spring Batch | `DatadogJobListener.java` — OpenTracing span tags for job metadata; `build.gradle` — adds `opentracing-api/util`; `Dockerfile` — `ADD dd-java-agent.jar` |

`account-service` is auto-instrumented entirely via the JVM agent flag
(`JAVA_TOOL_OPTIONS`) set in `docker-compose.datadog.yml` — no source patch
is applied to it.

### Regenerating patches

If you modify any instrumented source file, regenerate the patches from the
current uninstrumented state:

```bash
make uninstrument                  # must be in uninstrumented state first
python3 scripts/generate-patches.py
# verify all 5 pass
for p in scripts/patches/*.patch; do
  patch --dry-run -p1 -s --input "$p" && echo "OK: $p" || echo "FAIL: $p"
done
```

---

## Step-by-step breakdown

### Step 1 — Structured JSON logs (already active, no patch needed)

All six services already log in structured JSON. The Datadog Agent picks up
container stdout automatically via the `com.datadoghq.ad.logs` Docker label
set in `deploy/docker/docker-compose.datadog.yml`:

```yaml
labels:
  com.datadoghq.ad.logs: '[{"source":"python","service":"gateway-api"}]'
```

All six labels are already uncommented. No action required.

**Validate:** [Log Explorer](https://app.datadoghq.com/logs) → filter
`service:gateway-api` or `service:account-service`.

---

### Step 2 — Unified Service Tags (already active, no patch needed)

`DD_ENV`, `DD_SERVICE`, and `DD_VERSION` are already set in
`docker-compose.datadog.yml` for every service. No code change needed.

**Validate:** any log or trace should carry `env:staging service:<name> version:<sha>`.

---

### Step 3 — APM traces

**After `make instrument` + rebuild + restart**, traces are sent by:

| Service | Mechanism |
|---|---|
| `gateway-api` | `patch_all()` + `tracer.trace()` custom spans |
| `fraud-detection` | `patch_all()` + custom `fraud.score` span |
| `account-service` | `dd-java-agent.jar` via `JAVA_TOOL_OPTIONS` (no source patch) |
| `batch-processor` | `dd-java-agent.jar` via `JAVA_TOOL_OPTIONS` + `DatadogJobListener` spans |
| `transaction-service` | `require('dd-trace').init(...)` at top of `src/index.js` |
| `notification-service` | `tracer.Start()` in `main.go` |

**`account-service` specific:** the Dockerfile downloads `dd-java-agent.jar`
at build time (`ADD https://dtdg.co/latest-java-tracer /dd-java-agent.jar`
+ `RUN chmod 444`). `JAVA_TOOL_OPTIONS` in `docker-compose.datadog.yml`
activates it:

```yaml
JAVA_TOOL_OPTIONS: >-
  -javaagent:/dd-java-agent.jar
  -Ddd.logs.injection=true
  -Ddd.profiling.enabled=false
  -Ddd.data.jobs.enabled=false
```

**`batch-processor` specific:** same pattern, plus `-Ddd.data.jobs.enabled=true`
and the `DatadogJobListener` bean adds Finance-domain span tags
(`job.name`, `job.status`, `job.records_processed`) using the OpenTracing API
(`io.opentracing:opentracing-api:0.33.0` — required alongside `dd-trace-api`
since `dd-trace-api:1.x` does not expose `Span` or `activeSpan()` directly).

**Validate:** [APM → Services](https://app.datadoghq.com/apm/services). You
should see all six services within ~2 minutes of the first traffic.

---

### Step 4 — Log–trace correlation

Log correlation injects `dd.trace_id` and `dd.span_id` into every log record
so you can jump from a log line to the corresponding trace in APM.

| Service | Mechanism | Already in patch |
|---|---|---|
| `gateway-api` | `patch_logging()` from `ddtrace.contrib.logging` | ✅ |
| `fraud-detection` | same | ✅ |
| `account-service` | `-Ddd.logs.injection=true` JVM flag | ✅ (compose) |
| `batch-processor` | same | ✅ (compose) |
| `transaction-service` | `logInjection: true` in `dd-trace` init | ✅ |
| `notification-service` | automatic with `tracer.Start()` (Go stdlib) | ✅ |

**Validate:** Log Explorer → open any log from `gateway-api` → check for
`dd.trace_id` attribute → click **View Trace** button.

---

### Step 5 — Custom spans for business operations

`make instrument` uncomments these named spans:

| Service | Span name | Tags |
|---|---|---|
| `gateway-api` | `payment.authorize` | `transaction.type`, `payment.currency`, `account.id` |
| `gateway-api` | `account.balance_check` | `account.id`, `http.route` |
| `transaction-service` | `ledger.commit` | `transaction.type`, `payment.currency`, `db.instance` |
| `fraud-detection` | `fraud.score` | `fraud.score_bucket`, `account.id` |
| `notification-service` | `alert.send` | `notification.channel`, `jms.correlation_id`, `messaging.destination` |
| `batch-processor` | job metadata span | `job.name`, `job.status`, `job.records_processed` |

**Validate:** APM → Traces → search `resource_name:payment.authorize` or
`service:fraud-detection`.

---

### Step 6 — Custom metrics (DogStatsD)

`make instrument` uncomments DogStatsD emit calls. The Agent receives them on
`DD_AGENT_HOST:8125` (UDP). The `datadog` Python package and `dd-trace` Node
client are added to requirements/package.json by the dependency patches.

| Metric | Type | Tags | Service |
|---|---|---|---|
| `finance.payment.initiated` | counter | `transaction.type`, `payment.currency`, `status` | `gateway-api` |
| `finance.payment.processing_time` | histogram | `payment.currency` | `gateway-api` |
| `finance.notification.dispatch_time` | histogram | `channel`, `event_type` | `notification-service` |
| `finance.notification.sent` | counter | `channel`, `event_type` | `notification-service` |

> **Note:** `finance.batch.records_processed` and `finance.fraud.score` are
> generated in Datadog from APM span data via **Metrics from Spans** resources
> defined in `deploy/terraform/datadog/main.tf` — no DogStatsD client needed
> in those services.

**Validate:** [Metrics Explorer](https://app.datadoghq.com/metric/explorer) →
search `finance.*`.

---

### Step 7 — Continuous Profiler

`make instrument` uncomments profiler init for Python and Go. Java profiling
is enabled via JVM flags in `docker-compose.datadog.yml`.

| Service | How enabled |
|---|---|
| `gateway-api` | `import ddtrace.profiling.auto` at module load |
| `fraud-detection` | same |
| `account-service` | `-Ddd.profiling.enabled=true` (edit compose) |
| `batch-processor` | same |
| `transaction-service` | `profiling: true` in `dd-trace` init options |
| `notification-service` | `profiler.Start()` in `main.go` (uncommented by patch) |

**Validate:** [Continuous Profiler](https://app.datadoghq.com/profiling).

---

### Step 8 — Database Monitoring (PostgreSQL)

DBM is an **Agent-side feature** — no application code changes are needed.
It requires two one-time setup steps.

#### 8a. Create the monitoring user (run once)

```bash
# Run against the 'ledger' database
docker exec -i postgres-ledger psql -U finance -d ledger <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'datadog') THEN
    CREATE USER datadog WITH PASSWORD 'datadog_dbm_dev';
  ELSE
    ALTER USER datadog WITH PASSWORD 'datadog_dbm_dev';
  END IF;
END $$;
GRANT pg_monitor TO datadog;
GRANT SELECT ON pg_stat_database TO datadog;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements SCHEMA public;
SQL

# Also install the extension in the 'postgres' system database — the Agent
# probes all databases it can connect to. Without this, the check logs a
# WARNING about pg_stat_statements not found in dbname=postgres.
docker exec -i postgres-ledger psql -U finance -d postgres -c \
  "CREATE EXTENSION IF NOT EXISTS pg_stat_statements SCHEMA public;"
```

For EKS, the password is stored in Secrets Manager:
```bash
aws secretsmanager put-secret-value \
  --secret-id finance-app/staging/datadog-dbm-password \
  --secret-string "datadog_dbm_dev" \
  --profile <profile> --region <region>
```

#### 8b. Activate the Agent config

The config file at `deploy/docker/datadog-agent/conf.d/postgres.d/conf.yaml`
is already activated (uncommented). It is mounted into the Agent container at
`/etc/datadog-agent/conf.d/postgres.d/conf.yaml`. Restart the agent to reload:

```bash
docker restart datadog-agent
# or: make down-dd && make up-dd
```

**Validate:** [Databases → Query Metrics](https://app.datadoghq.com/databases).

---

### Step 9 — ActiveMQ JMX metrics

The Agent checks ActiveMQ via JMX on port 1099. The config at
`deploy/docker/datadog-agent/conf.d/activemq.d/conf.yaml` is already activated.

> **Requires `datadog/agent:7-jmx`** (the standard `7` image has no JRE).
> `deploy/docker/docker-compose.datadog.yml` already specifies `7-jmx`.

JMX auth is disabled on the dev container
(`-Dcom.sun.management.jmxremote.authenticate=false`), so no credentials are
needed. For staging/production, enable JMX auth in Artemis's `broker.xml`.

**Validate:** [Metrics Explorer](https://app.datadoghq.com/metric/explorer) →
search `activemq.artemis.*`.

---

### Step 10 — Datadog Terraform resources (metrics, monitors, dashboard)

Span-based metrics, log-based metrics, monitors, and the Finance dashboard are
managed as Terraform resources in `deploy/terraform/datadog/`.

```bash
# Export keys from AWS Secrets Manager
eval "$(make dd-secrets)"

# Apply all Datadog resources
make tf-apply-dd
```

This creates:
- `datadog_spans_metric` — `finance.payment.hits`, `finance.payment.duration`,
  `finance.fraud.hits`, `finance.batch.records`
- `datadog_logs_metric` — `finance.logs.errors`, `finance.logs.payments`
- Log index `finance-app` (15-day retention, filtered to `kube_namespace:finance`)
- Log pipeline (JSON parser for all finance services)
- Monitors (error rate, pod restarts, pods not running)
- Dashboard at the URL printed by `terraform output dashboard_url`

**Validate:** [Dashboards](https://app.datadoghq.com/dashboard/list) → search
`Finance Sample App`.

---

## Patch details

### What each patch file changes

| Patch file | Files modified | Key changes |
|---|---|---|
| `scripts/patches/gateway-api.patch` | `gateway-api/main.py`, `requirements.txt` | Uncomments `patch_all()`, `patch_logging()`, `tracer.trace()` spans, `statsd.*` calls; adds `ddtrace==2.9.0` and `datadog==0.49.1` |
| `scripts/patches/fraud-detection.patch` | `fraud-detection/main.py`, `requirements.txt` | Uncomments `patch_all()`, `patch_logging()`, `fraud.score` span; adds `ddtrace[data_streams]==2.9.0` |
| `scripts/patches/transaction-service.patch` | `src/index.js`, `package.json` | Uncomments `require('dd-trace').init(...)` with log injection and runtime metrics; adds `dd-trace: ^5.0.0` |
| `scripts/patches/notification-service.patch` | `main.go`, `go.mod` | Uncomments `tracer.Start()`, `profiler.Start()`, `tracer.StartSpanFromContext()`, statsd calls; activates `require` block in go.mod |
| `scripts/patches/batch-processor.patch` | `DatadogJobListener.java`, `build.gradle`, `Dockerfile` | Uncomments OpenTracing imports and span tag calls; adds `opentracing-api:0.33.0` + `opentracing-util:0.33.0`; uncomments `ADD dd-java-agent.jar` |

### Makefile targets

| Target | Description |
|---|---|
| `make instrument` | Apply all 5 patches (uncomment all Datadog blocks) |
| `make uninstrument` | Reverse all 5 patches (re-comment all Datadog blocks) |
| `make build` | Rebuild all images for the local platform (Docker Compose / Colima) |
| `make build-ecr` | Rebuild all images for `linux/amd64` and push to ECR (EKS) |
| `make up-dd` | Start the stack with the Datadog Agent |
| `make down-dd` | Stop the Datadog stack |
| `make tf-apply-dd` | Apply Datadog Terraform resources (metrics, monitors, dashboard) |
| `make dd-secrets` | Print `eval`-ready `export TF_VAR_*` commands from Secrets Manager |

---

## Troubleshooting

### Agent integration checks failing

```bash
# Check all integration statuses
docker exec datadog-agent agent status

# Reload config without full restart
docker exec datadog-agent agent reload-check postgres
```

Common issues:
- **`no valid instances`** — config file is still fully commented. Uncomment
  the `instances:` block.
- **`java: executable not found`** — agent image is `datadog/agent:7` not `7-jmx`.
  Update the image tag and restart.
- **`pg_stat_statements not created`** — run the prerequisite SQL in Step 8a.

### APM — service not appearing

1. Confirm `DD_AGENT_HOST=datadog-agent` is set in the service's environment.
2. Confirm the agent container is reachable: `docker exec <service> ping -c1 datadog-agent`.
3. For Java: confirm `dd-java-agent.jar` exists in the image (`docker run --rm <image> ls -la /dd-java-agent.jar`) and has world-readable permissions (`chmod 444`).
4. For Node.js: confirm `dd-trace` is the **first** `require()` in `src/index.js`.

### `make instrument` patch failure

If a patch fails with "hunk failed":

```bash
make uninstrument   # restore clean state (safe even if partially applied)
python3 scripts/generate-patches.py   # regenerate from current file state
make instrument     # re-apply
```

If the source files are in a mixed state (some hunks applied, some not), reset
with git:

```bash
git checkout HEAD -- gateway-api/main.py transaction-service/src/index.js \
  fraud-detection/main.py notification-service/main.go notification-service/go.mod \
  batch-processor/src/main/java/com/example/finance/batch/listener/DatadogJobListener.java \
  batch-processor/build.gradle batch-processor/Dockerfile
```

---

## Validated state (as of last run)

The following was validated against a local Docker stack with `make up-dd`:

| Signal | Status | Notes |
|---|---|---|
| APM — `gateway-api` | ✅ | Traces, custom spans, log correlation |
| APM — `account-service` | ✅ | Auto-instrumented via dd-java-agent |
| APM — `transaction-service` | ✅ | dd-trace init, log injection |
| APM — `fraud-detection` | ⚠️ | Active when payments flow through STOMP queue |
| APM — `notification-service` | ⚠️ | Active when alerts flow through STOMP queue |
| APM — `batch-processor` | ⚠️ | Active on scheduled job runs |
| Logs | ✅ | All 6 services collected; 1700+ logs/run |
| Log–trace correlation | ✅ | `dd.trace_id` injected by ddtrace / dd-java-agent |
| Metric — `finance.payment.initiated` | ✅ | DogStatsD counter |
| Metric — `finance.payment.processing_time` | ✅ | DogStatsD histogram |
| DBM — PostgreSQL | ✅ | 1400+ metric samples, query samples, schema monitoring |
| ActiveMQ JMX | ✅ | 30 metrics from broker + queue beans |

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
| Database Monitoring | https://docs.datadoghq.com/database_monitoring/ |
| DBM — PostgreSQL self-hosted | https://docs.datadoghq.com/database_monitoring/setup_postgres/selfhosted/ |
| ActiveMQ integration | https://docs.datadoghq.com/integrations/activemq/ |
| Unified Service Tagging | https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/ |
| Tagging best practices | https://docs.datadoghq.com/tagging/assigning_tags/ |
