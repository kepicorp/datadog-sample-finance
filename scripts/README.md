# scripts/ — Traffic Generator

This directory contains a traffic generator that drives realistic, mixed load against the
Finance Sample App stack running locally in Docker Compose.

---

## `generate-traffic.py`

A single-file Python script (standard library only — no `pip install` required) that:

1. Obtains JWT Bearer tokens for all four Keycloak finance-realm users
2. Seeds a set of test accounts directly on `account-service`
3. Runs a weighted random loop of Finance-domain scenarios against the three public services
4. Tokens are automatically refreshed before they expire

### Prerequisites

| Requirement | Detail |
|---|---|
| Python | 3.8+ (standard library only) |
| Running stack | `make deploy-k8s` from the project root |
| Keycloak | Healthy at `http://localhost:8089` (via `kubectl port-forward svc/keycloak 8089:8080 -n finance`) |

---

## Usage

Run from the project root (`impl/`):

```bash
# One pass through every scenario type — good for a quick smoke-test
python3 scripts/generate-traffic.py --once

# Continuous traffic at the default rate (1 req/s) — Ctrl-C to stop
python3 scripts/generate-traffic.py

# Higher rate
python3 scripts/generate-traffic.py --rate 5

# Run for a fixed window (e.g. 5 minutes to populate an APM dashboard)
python3 scripts/generate-traffic.py --rate 3 --duration 300
```

### Flags

| Flag | Default | Description |
|---|---|---|
| `--rate N` | `1.0` | Target requests per second |
| `--duration N` | `0` (forever) | Stop after N seconds |
| `--once` | — | Run one pass through each scenario, then exit |

---

## Services targeted

| Service | URL | Auth |
|---|---|---|
| `gateway-api` | `http://localhost:8080` | Bearer JWT (Keycloak) |
| `account-service` | `http://localhost:8081` | None (internal) |
| `transaction-service` | `http://localhost:8082` | None (internal) |
| Keycloak token endpoint | `http://localhost:8089` | Client credentials |

---

## Keycloak users

All four users in the `finance` realm are used, each representing a different
role encountered in a real banking platform:

| Username | Role | What they can do |
|---|---|---|
| `alice.analyst` | `finance-analyst` | Read-only: balance checks |
| `bob.trader` | `finance-trader` | Initiate payments and transfers |
| `carol.admin` | `finance-admin` | Full access |
| `dave.auditor` | `finance-auditor` | Read-only: compliance view |

Passwords: `Finance@2025!` (local dev only — see `identity-provider/README.md`).

---

## Traffic scenario breakdown

| Scenario | Weight | Services hit | HTTP method |
|---|---|---|---|
| Balance check (via gateway, JWT) | 30 % | gateway-api → account-service | `GET /v1/accounts/{id}/balance` |
| Payment initiation (via gateway, JWT) | 25 % | gateway-api → transaction-service → ActiveMQ | `POST /v1/payments` |
| Account lookup (direct) | 20 % | account-service → PostgreSQL | `GET /v1/accounts/{id}` + balance |
| Health checks (all services) | 10 % | gateway-api, account-service, transaction-service | `GET /health` |
| 404 — unknown resource | 7 % | account-service, transaction-service | `GET` missing IDs |
| 401 — no token | 5 % | gateway-api | `GET` + `POST` without `Authorization` header |
| 422 — bad payload | 3 % | gateway-api | `POST /v1/payments` with invalid body |

### Full request flow for a payment scenario

```
generate-traffic.py
  └─ POST /v1/payments  →  gateway-api :8080          (JWT validated)
       └─ POST /internal/transactions  →  transaction-service :8082
            ├─ ledger.commit()                          (in-memory stub)
            └─ JMS publish → fraud.score.queue
                  └─ fraud-detection                   (async consumer)
                        └─ JMS publish → alert.queue
                               └─ notification-service (async consumer)
```

Each payment triggers the full async chain through ActiveMQ Artemis, exercising
Data Streams Monitoring (DSM) paths when Step 10 of the Learning Progression is enabled.

---

## What to watch while the script runs

### Console UIs (no setup required)

| Console | URL | What to look for |
|---|---|---|
| ActiveMQ management | http://localhost:8161 | `fraud.score.queue` depth, consumer count |
| Keycloak admin | http://localhost:8089 | Active sessions per realm user |

Default ActiveMQ credentials: `admin` / `admin`.
Default Keycloak admin credentials: set in `.env` at the project root (`KEYCLOAK_ADMIN_PASSWORD`).

### Logs (Docker)

```bash
# All services combined
make logs

# Single service
docker logs -f gateway-api
docker logs -f transaction-service
docker logs -f fraud-detection
```

### PostgreSQL

```bash
# Connect directly (password from .env)
psql -h localhost -U $POSTGRES_USER -d ledger

# See accounts seeded by the script
SELECT id, owner_id, tier, currency, balance FROM accounts;
```

---

## Relationship to the Datadog Learning Progression

The traffic generator is useful at **every step** of the learning progression:

| Step | What the generator proves |
|---|---|
| Step 1 — Agent | Containers appear in the Datadog Infrastructure list |
| Step 2 — UST | `env`, `service`, `version` tags appear on all telemetry |
| Step 3 — APM | Traces appear in APM > Services; payment flow visible as a distributed trace |
| Step 4 — Logs | `dd.trace_id` appears in log records; "View in APM" button works |
| Step 5 — Custom spans | `payment.authorize`, `account.balance_check` spans appear in flame graphs |
| Step 6 — Metrics | `finance.payment.initiated`, `finance.payment.processing_time` in dashboards |
| Step 9 — DBM | Account and transaction queries appear in Databases > Query Samples |
| Step 10 — DSM | `fraud.score.queue` consumer lag visible in Data Streams > Pipeline |
| Step 12 — Synthetics | Use alongside Synthetic tests to compare real vs. scripted traffic |

Run `python3 scripts/generate-traffic.py --rate 3 --duration 300` before opening
each Datadog product page to ensure there is fresh telemetry to explore.
