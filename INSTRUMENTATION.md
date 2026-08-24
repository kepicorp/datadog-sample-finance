# Finance Sample App — Instrumentation Guide

This guide covers **what each observability signal enables and how to turn it on**, one pipeline stage at a time. Building images, loading them into the cluster, and deploying the app (local vs EKS) are covered once in the [README runbook](../README.md#testing-everything-manually) — those deployment mechanics are not repeated here.

---

## Quick Start

Everything below is opt-in and commented out by default. The full pipeline, in order:

```bash
make tags          # Unified Service Tagging + log injection
make dbm           # Database Monitoring (PostgreSQL)
make instrument    # APM custom spans + Single Step Instrumentation + Continuous Profiler
make dem           # Digital Experience Monitoring (Browser RUM)
make security      # ASM + CWS + CSPM
make tf-apply-dd   # Dashboards, monitors, SLOs, synthetics
```

Every stage has a reverse target (`make untag`, `make undbm`, `make uninstrument`, `make undem`, `make unsecurity`, `make tf-destroy-dd`) and is idempotent — running it twice in a row without reversing first is a safe no-op (tracked via a `.{stage}-applied` sentinel file).

**Nothing here is automatic.** A fresh `make deploy-k8s` + `make deploy-k8s-dd` does **not** enable Single Step Instrumentation, DBM, ASM/CWS/CSPM, UST, log injection, or RUM — all six manifests and the Agent config ship with these commented out. Each section below is the single source of truth for its stage's workflow.

---

## `make tags`

### What it does

Two narrated steps, applied via unified diff patches under `scripts/patches/tags/` (a separate directory from the top-level `scripts/patches/*.patch` used by `make instrument`, so the two lifecycles' globs never collide):

| Step | Target | Mechanism | What it enables |
|---|---|---|---|
| (a) UST | all 6 manifests | `scripts/patches/tags/ust-<service>.patch` | Uncomments `tags.datadoghq.com/env\|service\|version` pod labels + `DD_ENV`/`DD_SERVICE`/`DD_VERSION` env vars (`DD_AGENT_HOST` is untouched — always active, not a UST concern) |
| (b) Log injection — Python | `gateway-api`, `fraud-detection` | `scripts/patches/tags/loginject-<service>.patch` | Uncomments the `ddtrace.contrib.logging.patch` import + `patch_logging()` call |
| (b) Log injection — Node | `transaction-service` | `scripts/patches/tags/loginject-transaction-service.patch` | Uncomments `logInjection: true` in the `dd-trace` init block |
| (b) Log injection — Java | `account-service`, `batch-processor` | `scripts/patches/tags/loginject-<service>.patch` | Uncomments the `DD_LOGS_INJECTION=true` env var (dd-trace-java's Logback/Log4j2 MDC hook needs only this flag) |
| (b) Log injection — Go | `notification-service` | `scripts/patches/tags/loginject-notification-service.patch` | Uncomments manual `dd.trace_id`/`dd.span_id` field injection into the `alert.send`/`alert.send.complete` `slog` calls — Go has no automatic MDC-style hook |

> **Go log injection requires `make instrument` first.** The uncommented fields read `span.Context().TraceID()`/`SpanID()` off the `alert.send` span, which only exists once `make instrument` has uncommented it. Applying `make tags` alone leaves `notification-service` referencing an undefined `span` variable and it will fail to build.

### Why it matters

`DD_ENV`/`DD_SERVICE`/`DD_VERSION` (+ `tags.datadoghq.com/*` pod labels) are what let Datadog group traces/logs/metrics by service and correlate deploys via Deployment Tracking. Log injection stitches JSON logs to APM traces so "View in APM" works from Log Management — without it, logs and traces exist independently.

### Workflow

```bash
make tags               # apply UST + log injection patches
make build               # rebuild the service images
kubectl rollout restart deployment -n finance
```

### Reverse it

```bash
make untag               # re-comments all UST + log-injection patches
make build               # then reload images (if needed) + kubectl rollout restart deployment -n finance
```

### Validate

Any trace or log should carry `env:staging service:<name> version:latest`. Log Explorer → click any log from a finance service → **View Trace** button appears once `dd.trace_id` is present.

---

## `make dbm`

### What it does

Two narrated steps, sentinel `.dbm-applied`:

- **(a) Agent-side config** — applies `scripts/patches/dbm/dbm-agent.patch`, uncommenting the `postgres.d` check config and the `DD_DBM_POSTGRES_PASSWORD` wiring in `datadog-agent.yaml`. A ConfigMap/env var alone does nothing unless mounted like this.
- **(b) PostgreSQL role** — creates/refreshes the read-only `datadog` role, grants `pg_stat_statements`, and the `datadog.explain_statement` function (for EXPLAIN plans) by running `scripts/dbm-setup.sql` inside the `postgres-ledger` pod.

Password source order for step (b): the `datadog-secret` `dbm-password` key, else `DATADOG_DBM_PASSWORD` in `.env`. If neither is set, step (b) is skipped and DBM stays off at the DB level even though the Agent-side patch is applied. **This is no longer auto-run by `make deploy-k8s-dd`** — run `make dbm` explicitly after `make create-dd-secret` / `make deploy-k8s-dd`.

### Why it matters

DBM needs the Agent to authenticate to Postgres via a dedicated read-only role to collect query metrics, live query samples, and EXPLAIN plans — without code changes to `account-service`/`batch-processor`.

### Workflow

```bash
make dbm
# Redeploy the Agent to pick up the new mount:
#   Local: kubectl apply -k deploy/kubernetes/datadog/agent && kubectl rollout restart daemonset/datadog -n datadog
#   EKS:   kubectl apply -k deploy/kubernetes/overlays/eks-datadog && kubectl rollout restart daemonset/datadog -n datadog
```

### Reverse it

```bash
make undbm     # runs scripts/dbm-teardown.sql (revokes/drops the 'datadog' role), then reverses the Agent-side patch
```

`pg_stat_statements` the extension is left installed by `make undbm` — it's server-wide, not scoped to the role.

### Validate

Databases → Query Metrics — queries from `postgres-ledger` appear; open a sample → **Explain Plan** (available thanks to the `datadog.explain_statement` function from step (b)).

```bash
kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent status
# 'no valid instances'       → check YAML in deploy/kubernetes/datadog/checks/
# 'pg_stat_statements error' → make dbm step (b) hasn't run or failed
# 'authentication failed'    → verify dbm-password in the datadog-secret
```

---

## `make instrument`

Applies reversible unified-diff patches in three narrated steps under one sentinel (`.instrumentation-applied`). Reversing (`make uninstrument`) runs the same three steps in the opposite order.

### 1. APM custom spans

`scripts/patches/*.patch` (top-level directory — not `scripts/patches/tags/`, `dbm/`, `security/`, or `instrument-sso/`):

| Target | Mechanism | What it enables |
|---|---|---|
| `transaction-service` | `scripts/patches/transaction-service.patch` | Uncomments the `payment.authorize` custom span in `payments.js` |
| `notification-service` | `scripts/patches/notification-service.patch` | Uncomments `tracer.Start()` (APM), `profiler.Start()` (Continuous Profiler), and the `alert.send` custom span in `main.go` — all three live in the same patch/source banner |

> **Already active in source — no patch, always on:** `gateway-api` (`payment.authorize` / `account.balance_check`), `fraud-detection` (`fraud.score` span + `fraud.score_bucket` and numeric `fraud.score` tags), `batch-processor` (`job.name` / `job.status` / `job.records_processed` span tags). `account-service` has no custom instrumentation (Java agent auto-instrumentation only).
>
> **No DogStatsD anywhere.** Every `finance.*` custom metric is span-based (`datadog_spans_metric` in `deploy/terraform/datadog`, applied via `make tf-apply-dd`).

**Validate:** APM → Traces → filter by `resource_name:payment.authorize` or `operation_name:alert.send`.

### 2. Single Step Instrumentation gating

`scripts/patches/instrument-sso/sso-*.patch` — uncomments, on **all 6 service manifests**, the two things that opt a pod into tracer injection at startup:

**Pod label:**
```yaml
labels:
  admission.datadoghq.com/enabled: "true"
```

**Language annotation:**
```yaml
annotations:
  admission.datadoghq.com/python-lib.version: "v2"     # gateway-api, fraud-detection
  admission.datadoghq.com/js-lib.version: "v5"         # transaction-service
  admission.datadoghq.com/java-lib.version: "v1"       # account-service, batch-processor
  admission.datadoghq.com/go-lib.version: latest       # notification-service (no-op for Go — see note below)
```

Library versions are pinned to floating major tags (`v2`/`v1`/`v5`) rather than `latest` — reproducible across pod restarts, still receiving patches, always resolvable as init-image tags.

**Only after `make instrument` are these live** — before that, the label/annotation are commented out and the Datadog Operator's mutating admission webhook never touches these pods.

#### What gets injected

| Service | Library | Injection mechanism |
|---|---|---|
| `gateway-api` | `ddtrace` (Python) | `PYTHONPATH` + auto-instrumentation |
| `fraud-detection` | `ddtrace` (Python) | same |
| `transaction-service` | `dd-trace` (Node.js) | `NODE_OPTIONS=--require dd-trace/init` |
| `account-service` | `dd-java-agent` (Java) | `JAVA_TOOL_OPTIONS=-javaagent:...` |
| `batch-processor` | `dd-java-agent` (Java) | same |
| `notification-service` | `dd-trace-go` (Go) | **not single-step injected** — in-code `tracer.Start()`, see step 1 above |

The injected agent also sets `DD_TRACE_AGENT_URL`, `DD_INSTRUMENTATION_INSTALL_TYPE=k8s_lib_injection`, and `DD_APPSEC_ENABLED=true` (from the ASM feature flag, see `make security`) automatically.

> **What actually provides the tracer (important nuance):**
> - **Python** (`gateway-api`, `fraud-detection`) also pin `ddtrace` in their own `requirements.txt`, and that baked-in copy takes precedence over the injected library. So `import ddtrace` reports the **baked-in** version (currently `2.21.12`), not the injected one — changing the `python-lib.version` annotation alone has no effect for these two services. To move the Python tracer version, edit `requirements.txt` and rebuild the image.
> - **Go** (`notification-service`) is **not** single-step injected — the Admission Controller creates no init container for Go, so `go-lib.version` is a no-op. Go tracing comes entirely from the in-code `tracer.Start()` enabled in step 1 above.

#### Verify injection

```bash
# Init containers present?
kubectl get pod -n finance -l app=gateway-api \
  -o jsonpath='{.items[0].spec.initContainers[*].name}'
# Expected: datadog-lib-python-init datadog-init-apm-inject

# ddtrace version loaded?
kubectl exec -n finance deploy/gateway-api -- \
  python3 -c "import ddtrace; print(ddtrace.__version__)"

# Injection type env var?
kubectl exec -n finance deploy/gateway-api -- env | grep DD_INSTRUMENTATION
# Expected: DD_INSTRUMENTATION_INSTALL_TYPE=k8s_lib_injection
```

#### Admission Controller injection not working

```bash
# Required label on pod?
kubectl get pod -n finance -l app=gateway-api \
  -o jsonpath='{.items[0].metadata.labels.admission\.datadoghq\.com/enabled}'
# Expected: true

# Webhook registered?
kubectl get mutatingwebhookconfigurations datadog-webhook \
  -o jsonpath='{.webhooks[?(@.name=="datadog.webhook.lib.injection")].objectSelector}'
```

Common causes:
- **Label/annotation missing** — `make instrument` hasn't been run, or its patch failed (see [Makefile targets](#makefile-targets) → patch-failure recovery in [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)).
- **Operator not watching the namespace** — check `watchNamespaces` in Helm values.
- **Webhook not reconciled** — `kubectl logs -n datadog deploy/datadog-cluster-agent | grep -i admission`. This webhook has `failurePolicy: Ignore`, so pods still start successfully with **no error at all** — the only symptom is instrumentation silently not happening.

### 3. Continuous Profiler

`scripts/patches/instrument-sso/profiler-*.patch` — uncomments `DD_PROFILING_ENABLED=true` on **5 of 6 services** (Python: `gateway-api`, `fraud-detection`; Node: `transaction-service`; Java: `account-service`, `batch-processor` via `-Ddd.profiling.enabled=true`). **Not `notification-service`** — its Go profiler (`profiler.Start()`) is already gated by step 1's patch, in the same source banner as the Go APM tracer.

**Validate:** APM → Profiles — flame graphs appear within ~1 minute. Correlates CPU flame graphs with slow payment traces or slow batch job steps.

### Workflow

```bash
make instrument          # applies all 3 steps
make build                # rebuild the service images
# → reload the rebuilt images into your cluster (Colima/kind/k3d/minikube) — see the README runbook.
#   Docker Desktop / Rancher Desktop need no reload.
kubectl rollout restart deployment -n finance
```

> **EKS:** replace the local image reload with `make build-ecr && make deploy-k8s-eks`, then `kubectl rollout restart deployment -n finance`.

### Reverse it

```bash
make uninstrument       # reverses in opposite order: profiler → SSI gating → APM spans
make build               # then reload images (if needed) + kubectl rollout restart deployment -n finance
```

### Regenerating patches

If you modify any instrumented source file, regenerate the affected patch:

```bash
make uninstrument                        # must be in uninstrumented state first
python3 scripts/generate-patches.py     # regenerates service patches (gateway-api, fraud-detection, etc.)
for p in scripts/patches/*.patch; do
  patch --dry-run -p1 -s --input "$p" && echo "OK: $p" || echo "FAIL: $p"
done
```

**`scripts/patches/tags/*.patch` are hand-authored, not regenerated by this script.** `generate-patches.py`'s uncomment engine only understands Python/JS/Go/Java source syntax — it has no YAML support. If you modify a `tags/` patch's source, edit the corresponding `scripts/patches/tags/*.patch` unified diff by hand and re-validate with the same `patch --dry-run` loop.

---

## `make dem`

`make dem` turns on Digital Experience Monitoring (DEM) — Browser RUM + Session Replay — for the `frontend-stub/index.html` dashboard. Unlike `make instrument`/`make tags`/`make security`, it does not apply a patch: it creates the RUM application via a **direct Datadog API call** (`POST /api/v2/rum/applications` — not Terraform, not `terraform-provider-datadog`) and injects the resulting credentials with `sed`.

### What it does

1. Resolves `DD_API_KEY`/`DD_APP_KEY` via the shared `resolve_dd_keys` canned recipe — the same `.env` (local) / AWS Secrets Manager (EKS) resolution used by `make create-dd-secret` and `make tf-apply-dd`. No separate credential setup.
2. Checks for an existing RUM application named `finance-frontend` (`GET /api/v2/rum/applications`, filtered client-side by name — the list endpoint has no server-side name filter) to avoid creating a duplicate on repeated runs.
3. Creates one if none exists (`POST /api/v2/rum/applications`), or reuses the existing one's `id`/`client_token` (`GET /api/v2/rum/applications/{id}` — the list endpoint doesn't return `client_token`, only the single-resource GET does).
4. Caches `id`/`client_token` in the gitignored `.dem-state.json` so re-runs and `make undem` don't need to re-query the API.
5. Injects the credentials into `frontend-stub/index.html`'s `DD_RUM.init()` block via `sed`.

Idempotent: tracked via `.dem-applied`. A second run without `make undem` first is a no-op.

### Why it matters

RUM captures real browser sessions for the finance dashboard — page loads, clicks, errors — and Session Replay lets you watch exactly what a user saw. This is the frontend counterpart to `make instrument`/APM, which only covers backend spans. Independent of `make instrument`, `make tags`, and `make tf-apply-dd` — Terraform no longer creates any RUM resource at all.

### API schema

```
POST https://api.<site>/api/v2/rum/applications
Headers: DD-API-KEY, DD-APPLICATION-KEY, Content-Type: application/json
Body:
{
  "data": {
    "type": "rum_application_create",
    "attributes": { "name": "finance-frontend", "type": "browser" }
  }
}
Response (data.id is the applicationId; data.attributes.client_token is the clientToken):
{
  "data": {
    "id": "<uuid>",
    "type": "rum_application",
    "attributes": { "application_id": "<uuid>", "client_token": "pub...", "name": "finance-frontend", "type": "browser", "api_key_id": <int>, ... }
  }
}
```

`<site>` comes from `DD_SITE` in `.env` (default `datadoghq.com`).

### What gets enabled

| Feature | Config |
|---|---|
| Page view tracking | Automatic — all navigation events |
| User interactions | `trackUserInteractions: true` — clicks, form submits |
| Session Replay | `sessionReplaySampleRate: 100` — full replay recorded |
| PII masking | `defaultPrivacyLevel: 'mask-user-input'` — form values never recorded |
| Service | `finance-frontend` — appears in RUM > Applications |

#### Finance-specific RUM actions (already instrumented in the dashboard)

The dashboard JS calls `appLog()`, wired to emit structured console events. After enabling RUM, replace `appLog()` calls with `DD_RUM.addAction()` to surface Finance-domain actions:

| Action | Trigger | Tags to add |
|---|---|---|
| `payment.initiated` | `POST /v1/payments` success | `amount_bucket`, `currency` |
| `balance.checked` | `GET /v1/accounts/{id}/balance` | `account_tier` |
| `login.success` | Keycloak token issued | `role` |
| `payment.validated` | Compliance role approves/rejects | `decision` |

**PII cardinality warning** — never pass raw `account_id`, `payment_id`, or exact amounts as RUM action attributes:
```javascript
amount_bucket: amount < 100 ? '<100' : amount < 1000 ? '100-1000' : '>1000'
```

### Workflow

```bash
make dem                # create/find the RUM app, inject credentials into frontend-stub/index.html
```

**Frontend RUM is special:** the dashboard HTML is served from the `frontend-dashboard` ConfigMap, *not* the container image, so a plain `rollout restart` alone replays the old HTML:

```bash
kubectl create configmap frontend-dashboard \
  --from-file=index.html=frontend-stub/index.html \
  -n finance --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/frontend -n finance
```

### Reverse it

```bash
make undem              # deletes the RUM application via the API, restores the frontend placeholders
```

If `DD_API_KEY`/`DD_APP_KEY` can't be resolved, `make undem` fails with a clear error and leaves `.dem-applied`/`.dem-state.json`/the frontend untouched — retry once credentials are available.

### Validate

RUM → Applications → `finance-frontend` → Sessions → click any session → Session Replay available.

Docs: https://docs.datadoghq.com/real_user_monitoring/browser/

---

## `make security`

### What it does

Two narrated steps, one sentinel (`.security-applied`):

- **(a) Agent-side** — `scripts/patches/security/agent-security.patch` uncomments the `asm`/`cws`/`cspm` feature blocks in `datadog-agent.yaml`.
- **(b) App-side** — `scripts/patches/security/appsec-<service>.patch` (all 6 services) uncomments each service's `DD_APPSEC_ENABLED` env entry.

#### Agent configuration (uncommented by step (a))

```yaml
features:
  asm:
    threats:
      enabled: true
    sca:
      enabled: true
  cws:
    enabled: true
    syscallMonitorEnabled: true
  cspm:
    enabled: true
    hostBenchmarks:
      enabled: true
```

#### What is enabled

| Product | Layer | Detects |
|---|---|---|
| **ASM Threats** | APM tracer (app-side) | SQLi, XSS, SSRF, credential stuffing, business-logic attacks |
| **ASM SCA** | Agent-side | Known CVEs in Python / Java / Node.js / Go dependencies |
| **CWS** | Agent eBPF (kernel) | Shell spawned in container, file writes, privilege escalation, syscall anomalies |
| **CSPM** | Agent + cloud APIs | Privileged pods, exposed secrets, insecure RBAC, CIS / PCI-DSS findings |

### Why it matters

These agent features turn on the threat-intake pipeline, eBPF runtime monitoring, and CIS benchmark checks; the tracer needs `DD_APPSEC_ENABLED=true` to actually instrument requests for SQLi/XSS/SSRF/business-logic threats.

### Workflow

```bash
make security
# Redeploy to activate:
#   Agent: kubectl apply -k deploy/kubernetes/datadog/agent && kubectl rollout restart daemonset/datadog -n datadog
#   Apps:  make build && load images into k3s && kubectl rollout restart deployment -n finance
```

### Reverse it

```bash
make unsecurity          # restores every file to its original commented-out state
```

### Validate

```bash
# ASM active on gateway-api?
kubectl exec -n finance deploy/gateway-api -- env | grep DD_APPSEC_ENABLED
# Expected: DD_APPSEC_ENABLED=true

# CWS self-tests passed?
kubectl exec -n datadog daemonset/datadog-agent -c security-agent -- \
  security-agent status | grep -A10 "Self Tests"
# Expected: Succeeded: rule_open, rule_chmod, rule_chown — Failed: none
```

#### Finance-specific threat rules (configure in UI)

| Rule | Trigger | Action |
|---|---|---|
| Brute force on `/v1/payments` | > 10 `POST /v1/payments` with 401/422 from same IP in 1m | Block + alert |
| Account enumeration | > 20 `GET /v1/accounts/{id}` 404 from same IP in 1m | Alert |
| High payment velocity | > 5 `POST /v1/payments` from same `account_id` in 1m | Alert |

Docs:
- ASM: https://docs.datadoghq.com/security/application_security/
- CWS: https://docs.datadoghq.com/security/cloud_workload_security/
- CSPM: https://docs.datadoghq.com/security/cloud_security_management/misconfigurations/

---

## `make tf-apply-dd`

### What it does

Applies Terraform under `deploy/terraform/datadog` to create/update live Datadog configuration:

```bash
eval "$(make dd-secrets)"   # exports TF_VAR_datadog_api_key / TF_VAR_datadog_app_key
                            # priority: AWS Secrets Manager (active SSO session + secrets exist), else .env
make tf-apply-dd
```

| Resource | What it is |
|---|---|
| Log index `finance-logs` | 15-day retention, `kube_namespace:finance` filter |
| Log pipeline | JSON parser + trace ID remapper + service remapper |
| `finance.payment.hits` | Spans metric — `gateway-api` POST /v1/payments |
| `finance.payment.duration` | Distribution spans metric (p95 latency) |
| `finance.fraud.hits` | Spans metric — `fraud-detection` |
| `finance.batch.records_processed` | Spans metric — `batch-processor` |
| `finance.logs.errors` | Logs metric — error count by service |
| 7 monitors | Pod restarts, error rate, payment latency, payment errors, fraud queue, stuck transactions, pods not running |
| 3 SLOs | Payment availability (99.9%), payment latency (99%), fraud consumer (99.5%) |
| Dashboard | Finance App overview (APM, span-based metrics, DBM, ActiveMQ) |
| 7 Synthetic API tests | See below |
| 4 Security monitors | `asm_high_severity_attacks`, `asm_brute_force`, `cws_critical_signal`, `cspm_critical_findings` |

**Not RUM** — RUM is created and owned entirely by `make dem`, above.

All `finance.*` custom metrics referenced here are span-based (`datadog_spans_metric`, generated from the custom spans described in `make instrument` and the always-on spans in `gateway-api`/`fraud-detection`/`batch-processor`) — there is no DogStatsD in this app. Defined in `deploy/terraform/datadog/main.tf`. Docs: https://docs.datadoghq.com/tracing/trace_pipeline/generate_metrics/

### Synthetic tests

Generated from real observed traffic (APM span aggregation on `env:staging`):

| Observed baseline | p95 |
|---|---|
| `GET /health` (all services) | < 6ms |
| `GET /v1/accounts/{id}/balance` | 16ms |
| `POST /v1/payments` | 24ms |
| `POST /v1/accounts` | **575ms** ⚠️ (cold connection pool) |

| # | File | Test | Tier |
|---|---|---|---|
| 1 | `synthetics/health-check.yaml` | Health check — all services | Critical |
| 2 | `synthetics/payment-flow.yaml` | Payment happy path (POST → GET) | Critical |
| 3 | `synthetics/balance-check.yaml` | Authenticated balance check | Critical |
| 4 | `synthetics/unauthenticated-rejection.yaml` | No token → 401 | Security |
| 5 | `synthetics/payment-bad-payload.yaml` | Bad payload → 422 (not 500) | Negative |
| 6 | `synthetics/account-not-found.yaml` | Missing account → 404 | Negative |
| 7 | `synthetics/account-creation-latency.yaml` | Latency baseline (p95=575ms) | Latency |

Every test request carries `x-datadog-trace-id` automatically — click **View Trace** in any test result to jump to the full APM waterfall.

### Reverse it

```bash
make tf-destroy-dd     # WARNING: deletes the log index (and all indexed logs), monitors, dashboard, SLOs
```

### Validate

[Dashboards](https://app.datadoghq.com/dashboard/list) → search `Finance App`.

Docs:
- Synthetic Monitoring: https://docs.datadoghq.com/synthetics/
- Synthetic → APM correlation: https://docs.datadoghq.com/synthetics/apm/

---

## Other signals (always on, not gated by a pipeline stage)

A few signals are neither commented-out-by-default nor controlled by any `make` target above — they come from the base manifests or from `make deploy-k8s`/`make deploy-k8s-dd` unconditionally.

### Structured JSON logs

All six services emit structured JSON to stdout, collected by the Agent DaemonSet's `/var/log/pods/` volume mount. Each pod template carries an autodiscovery annotation:

```yaml
annotations:
  ad.datadoghq.com/gateway-api.logs: '[{"source":"python","service":"gateway-api"}]'
```

**Validate:** Log Explorer → `kube_namespace:finance`.

### ActiveMQ JMX metrics

Applied automatically by `make deploy-k8s-dd`:

```bash
kubectl apply -f deploy/kubernetes/datadog/checks/activemq-check.yaml
```

**Validate:** Infrastructure → Metrics → search `activemq.queue.size`.

### Data Streams Monitoring (DSM), JMS pipeline

`DD_DATA_STREAMS_ENABLED=true` is already set on the four JMS services (`account-service`, `transaction-service`, `fraud-detection`, `notification-service`) — no `make` target gates this. Gives producer→consumer latency and consumer-lag visibility across the payment → fraud → notification flow. `account-service` (Java) auto-instruments JMS producer/consumer checkpoints; the Node.js producer and Python/Go consumers may need manual checkpoints for complete end-to-end stitching.

**Validate:** Data Streams → pathway map shows `fraud.score.queue` and `alert.queue`. Docs: https://docs.datadoghq.com/data_streams/

### Data Jobs Monitoring (DJM), batch-processor

`DD_DATA_JOBS_ENABLED=true` is already set on `batch-processor` (equivalent to `-Ddd.data.jobs.enabled=true`) — no `make` target gates this. Surfaces Spring Batch job runs under APM → Data Jobs. Primarily built for Spark/Databricks workloads; for a plain Spring Batch app the APM spans + `job.*` tags already cover most needs.

**Validate:** APM → Data Jobs after a reconciliation run. Docs: https://docs.datadoghq.com/data_jobs/

---

## Service Catalog: `service.datadog.yaml`

A static, git-committed service metadata file — team ownership (`contacts`), links, lifecycle/tier — the counterpart to what Service Catalog otherwise infers at runtime from APM tags. One file per service, at the root of each service's directory (`gateway-api/service.datadog.yaml`, `account-service/service.datadog.yaml`, `transaction-service/service.datadog.yaml`, `fraud-detection/service.datadog.yaml`, `notification-service/service.datadog.yaml`, `batch-processor/service.datadog.yaml`).

### Schema used in this repo

Confirmed against `gateway-api/service.datadog.yaml` and `notification-service/service.datadog.yaml`:

```yaml
apiVersion: v3
kind: service
metadata:
  name: gateway-api
  displayName: Gateway API
  tags:
    - env:staging
    - language:python
    - team:finance-platform
  links:
    - name: Source
      type: repo
      provider: github
      url: https://github.com/your-org/finance-sample-app/tree/main/gateway-api
  contacts:
    - name: Finance Platform
      type: email
      contact: finance-platform@example.com
spec:
  lifecycle: staging
  tier: High
  type: service
  languages:
    - python
  description: |
    Public-facing REST API. Handles OIDC auth, routes to account-service and transaction-service.
```

`metadata.{name,displayName,tags,links,contacts}` and `spec.{lifecycle,tier,type,languages,description}` — unaffected by Phase A's instrumentation changes.

### How they're loaded

Once Datadog's GitHub integration is installed (**Integrations → GitHub → Repo Configuration → "Link GitHub Account"**), Datadog automatically scans every repository it has read access to for files named `service.datadog.yaml` (and `entity.datadog.yaml`) **anywhere in the repo tree** — not just the root — with no explicit push or CI step required. The API is available as an alternative manual-import path for teams not using the GitHub integration.

---

## Makefile targets

Instrumentation-lifecycle targets only. For build/deploy/AWS-infrastructure targets, see the [README](../README.md).

| Target | What it does |
|---|---|
| `make tags` | Enable Unified Service Tagging + log injection (all 6 manifests) via patches |
| `make untag` | Reverse all Tags + log-injection patches |
| `make dbm` | Enable Database Monitoring — Agent-side config + PostgreSQL `datadog` role |
| `make undbm` | Reverse Database Monitoring — drops the PostgreSQL role, reverses Agent-side config |
| `make instrument` | Enable APM custom spans + Single Step Instrumentation gating + Continuous Profiler via patches |
| `make uninstrument` | Reverse all `make instrument` patches |
| `make dem` | Create the Browser RUM application via a direct Datadog API call and inject credentials into `frontend-stub/index.html`. Idempotent (`.dem-applied` + `.dem-state.json`) |
| `make undem` | Delete the RUM application via the Datadog API; restore frontend RUM placeholder tokens |
| `make security` | Enable ASM Threats/SCA, CWS, CSPM — Agent-side config + `DD_APPSEC_ENABLED` on all 6 services |
| `make unsecurity` | Reverse all `make security` patches |
| `make tf-apply-dd` | Apply Datadog Terraform resources (monitors, SLOs, dashboard, synthetics, log pipeline) |
| `make tf-destroy-dd` | Destroy Datadog Terraform resources |

> **Port-forward note:** `make test` and `make test-traffic` connect to services from your laptop and need manual port-forwards first — see the [README](../README.md) for the commands. You normally don't need either: the in-cluster `traffic-generator` Deployment already generates continuous traffic with no port-forward needed for Datadog telemetry.
