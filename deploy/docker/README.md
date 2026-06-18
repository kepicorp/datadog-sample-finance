# Docker Compose — Finance Sample App

Two Compose files are provided so you can verify the application works before
adding any Datadog instrumentation:

| File | Purpose | Command |
|---|---|---|
| `docker-compose.base.yml` | **No Datadog** — clean app stack | `make up` |
| `docker-compose.datadog.yml` | **With Datadog Agent** — full observability | `make up-dd` |

---

## Quick Start (no Datadog required)

### 1. Configure environment variables

```bash
cp .env.example .env
```

Open `.env` and set at minimum:

| Variable | Description |
|---|---|
| `POSTGRES_USER` | PostgreSQL superuser name (e.g. `ledger_user`) |
| `POSTGRES_PASSWORD` | Strong password |
| `ARTEMIS_USER` | ActiveMQ admin username |
| `ARTEMIS_PASSWORD` | Strong password |

`DD_API_KEY` is only needed when using `make up-dd`. Leave it blank for the base stack.

> **Security:** `.env` contains secrets. It is covered by `.gitignore` and must never be committed.

### 2. Build and start

```bash
make build   # build all service images
make up      # start the stack (no Datadog)
```

### 3. Verify

```bash
make health  # → {"status":"ok","service":"gateway-api"}
make test    # → 37/37 tests passed
```

### 4. Open the dashboard

Dashboard (nginx frontend): http://localhost:3000

Login with any Keycloak user (password `Finance@2025!`):

| Username | Role | Can do |
|---|---|---|
| `alice.analyst` | finance-analyst | Read-only |
| `bob.trader` | finance-trader | Initiate payments, transfers |
| `carol.admin` | finance-admin | Full access, deposits |
| `dave.auditor` | finance-auditor | Read-only |
| `eve.compliance` | finance-compliance | Validate/approve payments |

---

## Starting with the Datadog Agent

```bash
# Add your API key to .env first:
# DD_API_KEY=<your key from https://app.datadoghq.com/organization-settings/api-keys>

make up-dd
```

The Datadog Agent starts alongside the application. Follow the 12-step
Learning Progression in each service's README to progressively enable
APM, logs, metrics, DBM, DSM, and profiling.

---

## Useful commands

```bash
make up              # start base stack (no Datadog)
make up-dd           # start with Datadog Agent
make down            # stop base stack
make down-dd         # stop Datadog stack
make logs            # tail all logs
make health          # check gateway-api /health
make test            # run full e2e test suite (37 assertions)
make test-traffic    # generate 60 s of realistic traffic
make clean-data      # reset in-memory state (accounts + payments)
make reset-db        # full PostgreSQL + Redis reset
make restart         # force-recreate app containers (fixes stale DNS)
```

---

## Services and ports

| Service | URL | Notes |
|---|---|---|
| Frontend dashboard | http://localhost:3000 | nginx + Keycloak login |
| gateway-api | http://localhost:8080 | REST API (JWT required) |
| account-service | http://localhost:8081 | Account CRUD (internal) |
| transaction-service | http://localhost:8082 | Payment processing (internal) |
| Keycloak admin | http://localhost:8089 | Identity provider |
| ActiveMQ console | http://localhost:8161 | Broker management |
| PostgreSQL | localhost:5432 | Database: `ledger` |
| Redis | localhost:6379 | Session cache |

---

## Learning Progression (with `make up-dd`)

| Step | What to uncomment | Where to verify |
|---|---|---|
| 1 | `DD_API_KEY` in `.env`, restart Agent | Infrastructure > Containers |
| 2 | `DD_ENV`, `DD_SERVICE`, `DD_VERSION` already set per-service | Any telemetry view |
| 3 | APM init block in each service; `JAVA_TOOL_OPTIONS` for Java | APM > Services |
| 4 | `com.datadoghq.ad.logs` labels per service | Log Management |
| 5 | Custom spans around `payment.authorize`, `fraud.score` | APM > Traces |
| 6 | DogStatsD metric emission (`finance.payment.initiated`, etc.) | Metrics Explorer |
| 7 | `DD_PROFILING_ENABLED=true` / `-Ddd.profiling.enabled=true` | APM > Profiles |
| 8 | RUM Browser SDK in `frontend-stub/index.html` | RUM > Sessions |
| 9 | `datadog-agent/conf.d/postgres.d/conf.yaml` DBM config | Databases > Query Metrics |
| 10 | `DD_DATA_STREAMS_ENABLED=true` on JMS services | Data Streams |
| 11 | `DD_DATA_JOBS_ENABLED=true` on `batch-processor` | Data Jobs |
| 12 | Synthetic tests from `synthetics/` | Synthetics > Tests |

---

## Directory layout

```
deploy/docker/
  docker-compose.base.yml     No Datadog — clean app stack
  docker-compose.datadog.yml  With Datadog Agent + DD_* env vars
  .env.example                Template — copy to .env
  .env                        Local secrets (git-ignored)
  datadog-agent/
    conf.d/
      postgres.d/conf.yaml    DBM check config (commented — Step 9)
      activemq.d/conf.yaml    ActiveMQ JMX check (commented — Step 10)
```

---

## Differences between the two Compose files

`docker-compose.datadog.yml` adds to every service:
- `DD_SERVICE`, `DD_ENV`, `DD_VERSION` — Unified Service Tags
- `DD_AGENT_HOST`, `DD_TRACE_AGENT_PORT`, `DD_DOGSTATSD_PORT` — Agent connection
- `DD_RUNTIME_METRICS_ENABLED` — language runtime metrics
- `datadog-run:/var/run/datadog` volume — UDS socket for low-latency comms
- `com.datadoghq.tags.*` Docker labels — container metadata for the Agent

It also adds:
- The `datadog-agent` container itself (`datadog/agent:7`)
- The `datadog-run` named volume (shared UDS socket directory)
- `depends_on: datadog-agent: condition: service_started` on all app services

Everything else (ports, health checks, application env vars, volumes) is
**identical** between the two files.
