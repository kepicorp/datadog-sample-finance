# Finance Sample App — Instrumentation Guide

This guide covers **what each observability layer enables and how to turn it on**.
Building images, loading them into the cluster, and deploying the app (local vs EKS)
are covered once in the [README runbook](../README.md#testing-everything-manually) —
those deployment mechanics are not repeated here.

---

## How instrumentation is layered

Two complementary layers — both independent, both reversible:

| Layer | What it does | How |
|---|---|---|
| **1 — Single-step (Admission Controller)** | Injects the Datadog tracer into every pod at startup — no code changes, no rebuilds | `admission.datadoghq.com/enabled: "true"` label + Operator webhook |
| **2 — Manual (`make instrument`)** | Adds custom business spans, Finance-domain tags, DogStatsD metrics, and the Browser RUM SDK | Unified diff patches — fully reversible with `make uninstrument` |

- **Layer 1** is automatic once the Agent is deployed (`make deploy-k8s-dd`): distributed tracing, log–trace correlation, and runtime metrics, with zero code changes.
- **Layer 2** is opt-in via `make instrument` and enriches Layer 1 with business context. The [Enabling Layer 2](#enabling-layer-2-make-instrument) section is the single source of truth for that workflow.

### What enables what

Not everything is `make instrument` — that's the most common point of confusion. Each signal is turned on by exactly **one** of these mechanisms:

| Mechanism | Turned on by | What it enables |
|---|---|---|
| Layer 1 — Admission Controller injection | `make deploy-k8s-dd` (automatic) | APM traces, log–trace correlation, runtime metrics (UST + JSON logs are already in the manifests) |
| Agent-side config | `make deploy-k8s-dd` (agent + checks) | DBM (Postgres), ActiveMQ JMX, **Security (ASM / CWS / CSPM)**, log collection |
| Per-service env / already in source | manifest env var or source code | **Continuous Profiler** (`DD_PROFILING_ENABLED`; the Go service already calls `profiler.Start()`) |
| **Layer 2 — `make instrument`** | `make instrument` | Custom spans + DogStatsD **for `fraud-detection` & `transaction-service` only**, plus RUM credential injection |
| Terraform | `make tf-apply-dd` | Monitors, SLOs, dashboard, synthetics, log pipeline, the RUM application |

**So `make instrument` is deliberately narrow.** It does **not** enable profiling or security — those come from the Agent config / env vars above. And `gateway-api`, `notification-service`, and `batch-processor` ship with their custom spans/metrics/profiler **already active in source** (not comment-gated), so they need no patch.

The [Signal reference](#signal-reference) lists each signal with an explicit **Enabled by:** line.

---

## Enabling Layer 2 (`make instrument`)

`make instrument` applies reversible unified-diff patches that uncomment custom spans, DogStatsD metrics, and the Browser RUM SDK. **This is the one and only Layer 2 workflow** — every "Step" below marked *Layer 2* refers back here rather than repeating it.

### What `make instrument` actually changes

Only code that ships **commented out** is toggled — currently **two services** — plus a RUM credential injection:

| Target | Mechanism | What it enables |
|---|---|---|
| `fraud-detection` | `scripts/patches/fraud-detection.patch` | DogStatsD fraud-score gauge (`statsd.gauge`) + statsd init in `listener.py` |
| `transaction-service` | `scripts/patches/transaction-service.patch` | `payment.authorize` span + DogStatsD payment metrics (`payment.initiated`, `payment.processing_time`, `payment.validated`, `ledger.commit.errors`) across `payments.js` / `ledger.js` / `producer.js` |
| `frontend-stub/index.html` | `sed` credential injection (**not a patch**) | Fills the RUM `applicationId` / `clientToken` from `terraform output` into the already-present `DD_RUM.init()` block |

> **Already active in source — no patch, always on:**
> - `gateway-api` — `payment.authorize` / `account.balance_check` spans + `finance.payment.*` DogStatsD
> - `notification-service` — `alert.send` span **and `profiler.Start()`** (Go continuous profiler)
> - `batch-processor` — `job.name` / `job.status` / `job.records_processed` span tags
>
> `make instrument` / `make uninstrument` do **not** touch these — they run whenever the service runs. `account-service` has no custom instrumentation (relies entirely on Java agent auto-instrumentation).

### ⚠️ RUM requires `make tf-apply-dd` first

`make instrument` injects the RUM `applicationId` and `clientToken` into `frontend-stub/index.html` by reading `terraform output` from `deploy/terraform/datadog`. That output only exists after `make tf-apply-dd` has created `datadog_rum_application.finance_frontend` (see [Step 11](#step-11--datadog-terraform-resources) for the `dd-secrets` / `TF_VAR_*` setup).

- **Run `make tf-apply-dd` before `make instrument`** for a working frontend RUM setup.
- If you instrument first, the **backend patches still apply** (spans, metrics, profiler) — only the RUM block stays on `REPLACE_WITH_APPLICATION_ID` / `REPLACE_WITH_CLIENT_TOKEN` placeholders and prints a `⚠`. Just re-run `make instrument` after `make tf-apply-dd` (it's idempotent).

### Workflow

```bash
make tf-apply-dd        # RUM prerequisite — creates the RUM app (skip only if you don't need RUM yet)
make instrument         # apply patches + inject RUM credentials
make build              # rebuild the service images
# → reload the rebuilt images into your cluster (Colima/kind/k3d/minikube) — see the README runbook.
#   Docker Desktop / Rancher Desktop need no reload.
kubectl rollout restart deployment -n finance
```

**Frontend RUM is special:** the dashboard HTML is served from the `frontend-dashboard` ConfigMap, *not* the container image, so a `rollout restart` alone replays the old HTML. After instrumenting, rebuild that ConfigMap and restart the frontend:

```bash
kubectl create configmap frontend-dashboard \
  --from-file=index.html=frontend-stub/index.html \
  -n finance --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/frontend -n finance
```

> **EKS:** replace the local image reload with `make build-ecr && make deploy-k8s-eks`, then `kubectl rollout restart deployment -n finance`.

### Reverse it

```bash
make uninstrument       # re-comments all patches, restores the RUM placeholders
make build              # then reload images (if needed) + kubectl rollout restart deployment -n finance
```

### Regenerating patches

If you modify any instrumented source file, regenerate the affected patch:

```bash
make uninstrument                        # must be in uninstrumented state first
python3 scripts/generate-patches.py     # regenerates service patches (gateway-api, fraud-detection, etc.)
# The frontend.patch is maintained manually — edit scripts/patches/frontend.patch directly
# if you change the RUM block in frontend-stub/index.html
for p in scripts/patches/*.patch; do
  patch --dry-run -p1 -s --input "$p" && echo "OK: $p" || echo "FAIL: $p"
done
```

---

## Secrets & Credentials

The app uses two separate secret stores — here is why:

| Store | What lives there | Why |
|---|---|---|
| `.env` (local file, git-ignored) | `DD_API_KEY`, `DD_APP_KEY`, `DATADOG_DBM_PASSWORD` | Never committed. Read by `make create-dd-secret` to populate K8s secrets. On EKS, fetched from AWS Secrets Manager instead. |
| `app-secrets` K8s Secret (`finance` namespace) | Application credentials (PostgreSQL, ActiveMQ, Keycloak) | Applied by `make deploy-k8s`. Pre-set with safe dev defaults in `02-secrets.yaml`. Rotate before staging/production. |
| `datadog-secret` K8s Secret (`datadog` namespace) | `DD_API_KEY`, `DD_APP_KEY`, `dbm-password` | Created by `make deploy-k8s-dd` (calls `make create-dd-secret` automatically). Read from `.env` locally or AWS Secrets Manager on EKS. |
| `keycloak-tls` K8s Secret (`finance` namespace) | Self-signed TLS cert for the nginx HTTPS proxy | Generated automatically by `make deploy-k8s`. Never committed. |

### Application secrets — `app-secrets` K8s Secret

Applied automatically by `make deploy-k8s` from `deploy/kubernetes/base/02-secrets.yaml`.
These are dev defaults — rotate all values before any staging or production deployment.

| Secret key | Dev value | Used by |
|---|---|---|
| `postgres-user` | `finance` | account-service, batch-processor |
| `postgres-password` | `finance_dev_password` | account-service, batch-processor |
| `artemis-user` | `admin` | all JMS services (ActiveMQ) |
| `artemis-password` | `artemis_dev_password` | all JMS services (ActiveMQ) |
| `keycloak-admin-password` | `Finance@Admin2025!` | Keycloak admin (internal use only) |
| `keycloak-client-secret` | `FuX1ZIddFs02LzJT-s5MZufplT7SzGmflb42_6P8VcI` | gateway-api OIDC validation, finance dashboard login |

To override any value, edit `deploy/kubernetes/base/02-secrets.yaml` before running `make deploy-k8s`, or patch the secret after deploy:

```bash
kubectl patch secret app-secrets -n finance \
  --type='json' \
  -p='[{"op":"replace","path":"/data/postgres-password","value":"'$(echo -n newpassword | base64)'"}]'
```

### Finance realm users

Pre-imported into the Keycloak `finance` realm. Log in at the Finance dashboard: `http://localhost:30080`. See root [README.md's "Finance realm users and roles"](../README.md#finance-realm-users-and-roles) for the full table of usernames, passwords, roles, and per-dashboard-card permissions — all 5 users share the password `Finance@2025!`.

### Datadog secrets — `datadog-secret` K8s Secret

Created automatically by `make deploy-k8s-dd`. Source depends on environment:

**Local — reads from `.env`:**
```bash
cp .env.example .env
# set DD_API_KEY and DD_APP_KEY in .env
make deploy-k8s-dd   # creates the secret then deploys the Agent
```

**EKS — reads from AWS Secrets Manager:**
```bash
aws sso login --profile partner
make deploy-k8s-dd   # auto-fetches from finance-app/staging/dd-{api,app}-key
```

| Key | Source | Notes |
|---|---|---|
| `api-key` | `DD_API_KEY` in `.env` / Secrets Manager | https://app.datadoghq.com/organization-settings/api-keys |
| `app-key` | `DD_APP_KEY` in `.env` / Secrets Manager | https://app.datadoghq.com/organization-settings/application-keys |
| `dbm-password` | `DATADOG_DBM_PASSWORD` in `.env` / Secrets Manager | Password you choose when running the DBM SQL setup (Step 9). Not pre-set — you must supply it. |

To create or rotate the secret independently of deploying the Agent:
```bash
make create-dd-secret
```

To verify what's stored:
```bash
kubectl get secret datadog-secret -n datadog \
  -o jsonpath='{.data}' | python3 -m json.tool
# Expected keys: api-key, app-key, dbm-password
```

**GitOps / production** — use the External Secrets Operator to sync from AWS Secrets Manager or Vault. An `ExternalSecret` manifest is in `deploy/kubernetes/datadog/secrets/datadog-secrets.yaml`.
Docs: https://external-secrets.io/

### TLS secret — `keycloak-tls`

Generated automatically by `make deploy-k8s` (idempotent — skipped if already exists).
Contains a self-signed certificate valid for `localhost` and `keycloak` for 10 years.
Used by nginx to serve Keycloak over HTTPS on port 30443.

On EKS, TLS is terminated by the NLB using an ACM certificate — `keycloak-tls` is not used.

---

## Datadog Operator (prerequisite)

`make deploy-k8s-dd` installs the Operator automatically (via Helm) if it's absent, then creates `datadog-secret` and deploys the Agent. To install it manually:

```bash
helm repo add datadog https://helm.datadoghq.com
helm install datadog-operator datadog/datadog-operator \
  --namespace datadog --create-namespace \
  --set watchNamespaces='{datadog,finance}'

make deploy-k8s-dd   # creates the datadog-secret from .env, then deploys the Agent
```

---

## Layer 1 — Single-step instrumentation (Admission Controller)

The Datadog Operator's **mutating admission webhook** injects the tracer library into pods at creation time via init containers. No application code changes or Docker image rebuilds required.

### What's needed on each pod

**Pod label** — opt the pod into webhook processing:
```yaml
labels:
  admission.datadoghq.com/enabled: "true"
```

**Language annotation** — tells the webhook which library to inject:
```yaml
annotations:
  admission.datadoghq.com/python-lib.version: "v2"     # gateway-api, fraud-detection
  admission.datadoghq.com/js-lib.version: "v5"         # transaction-service
  admission.datadoghq.com/java-lib.version: "v1"       # account-service, batch-processor
  admission.datadoghq.com/go-lib.version: latest       # notification-service (no-op for Go — see note below)
```

Both are already set in all six service manifests under `deploy/kubernetes/base/services/`. The library versions are **pinned to floating major tags** (`v2`/`v1`/`v5`) rather than `latest` — reproducible across pod restarts, still receiving patches, and always resolvable (exact patch tags don't reliably exist as init-image tags).

### What gets injected

| Service | Library | Injection mechanism |
|---|---|---|
| `gateway-api` | `ddtrace` (Python) | `PYTHONPATH` + auto-instrumentation |
| `fraud-detection` | `ddtrace` (Python) | same |
| `transaction-service` | `dd-trace` (Node.js) | `NODE_OPTIONS=--require dd-trace/init` |
| `account-service` | `dd-java-agent` (Java) | `JAVA_TOOL_OPTIONS=-javaagent:...` |
| `batch-processor` | `dd-java-agent` (Java) | same |
| `notification-service` | `dd-trace-go` (Go) | **not single-step injected** — in-code `tracer.Start()` (see note) |

The injected agent also sets `DD_TRACE_AGENT_URL`, `DD_INSTRUMENTATION_INSTALL_TYPE=k8s_lib_injection`, and `DD_APPSEC_ENABLED=true` (from the ASM feature flag) automatically.

### Verify injection

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

> **What actually provides the tracer (important nuance):**
> - **Python** (`gateway-api`, `fraud-detection`) also pin `ddtrace` in their own
>   `requirements.txt`, and that baked-in copy takes precedence over the injected
>   library. So `import ddtrace` (and the `__version__` command above) reports the
>   **baked-in** version (currently `2.21.12`), not the injected one — changing the
>   `python-lib.version` annotation alone has no effect for these two services. To
>   move the Python tracer version, edit `requirements.txt` and rebuild the image.
> - **Go** (`notification-service`) is **not** single-step injected — the Admission
>   Controller creates no init container for Go, so `go-lib.version` is a no-op.
>   Go tracing comes from the in-code `tracer.Start()` enabled in Layer 2.

---

## Signal reference

Each Datadog signal, the layer that provides it, and how to validate it. Signals marked **Layer 2** are turned on via [Enabling Layer 2](#enabling-layer-2-make-instrument) — that section holds the full workflow; the steps below only list what appears and how to check it.

### Step 1 — Structured JSON logs (always active)

All six services emit structured JSON to stdout. The Agent collects them via the DaemonSet `/var/log/pods/` volume mount. Each pod template carries an autodiscovery annotation:

```yaml
annotations:
  ad.datadoghq.com/gateway-api.logs: '[{"source":"python","service":"gateway-api"}]'
```

Already set in all six service manifests — no action required.

**Validate:** Log Explorer → `kube_namespace:finance`

### Step 2 — Unified Service Tags (always active)

`DD_ENV`, `DD_SERVICE`, `DD_VERSION`, `DD_AGENT_HOST`, and `tags.datadoghq.com/*` pod labels are set in every service manifest:

```yaml
env:
  - name: DD_ENV
    value: "staging"
  - name: DD_SERVICE
    value: "gateway-api"
  - name: DD_VERSION
    value: "latest"
  - name: DD_AGENT_HOST
    valueFrom:
      fieldRef:
        fieldPath: status.hostIP
```

Already set in all six manifests — no action required.

**Validate:** any trace or log should carry `env:staging service:<name> version:latest`.

### Step 3 — APM traces (Layer 1, automatic)

Traces appear automatically once the Admission Controller injects the tracer. No code changes required. To add custom business spans on top, see [Enabling Layer 2](#enabling-layer-2-make-instrument) (Step 5).

**Validate:** APM → Services — all six services appear within ~2 minutes of the first request.

### Step 4 — Log–trace correlation (automatic with Layer 1)

The injected tracer patches the logging framework to append `dd.trace_id` and `dd.span_id` to every log line. No code changes required.

**Validate:** Log Explorer → click any log from a finance service → "View Trace" button appears.

### Step 5 — Custom business spans

**Enabled by:** partly [`make instrument`](#enabling-layer-2-make-instrument), partly always-on in source.
- Via `make instrument`: `fraud.score` (fraud-detection), `payment.authorize` (transaction-service).
- Already active in source (appear as soon as the tracer is injected — no patch): `payment.authorize` / `account.balance_check` (gateway-api), `alert.send` (notification-service), `job.*` tags (batch-processor).

**Validate:** APM → Traces → filter by `resource_name:payment.authorize`

### Step 6 — Custom metrics (DogStatsD)

**Enabled by:** [`make instrument`](#enabling-layer-2-make-instrument) — the `fraud-detection` and `transaction-service` patches. (`gateway-api` also emits `finance.payment.*` metrics, already active in source.)

| Metric | Type | Tags |
|---|---|---|
| `finance.payment.initiated` | Counter | `transaction.type`, `currency` |
| `finance.payment.processing_time` | Histogram | `transaction.type` |
| `finance.fraud.score` | Gauge | `score_bucket` |

**Validate:** Metrics Explorer → search `finance.payment.initiated`

### Step 7 — Continuous Profiler

**Enabled by:** per-service config — **not `make instrument`.** `notification-service` (Go) already calls `profiler.Start()` in source. For the other services, set `DD_PROFILING_ENABLED=true` on the pod. Add it to any service manifest's env block:

```yaml
- name: DD_PROFILING_ENABLED
  value: "true"
```

For Java: add `-Ddd.profiling.enabled=true` to `JAVA_TOOL_OPTIONS`.

**Validate:** APM → Profiles — flame graphs appear within ~1 minute.

### Step 8 — Browser RUM + Session Replay (Layer 2)

The finance dashboard (`frontend-stub/index.html`) ships with the Browser RUM SDK carrying placeholder credentials. [`make instrument`](#enabling-layer-2-make-instrument) injects the real `applicationId`/`clientToken` from Terraform and you rebuild the `frontend-dashboard` ConfigMap — both covered in the Enabling Layer 2 workflow (note the ⚠️ **`make tf-apply-dd` must run first**).

#### What gets enabled

| Feature | Config |
|---|---|
| Page view tracking | Automatic — all navigation events |
| User interactions | `trackUserInteractions: true` — clicks, form submits |
| Session Replay | `sessionReplaySampleRate: 100` — full replay recorded |
| PII masking | `defaultPrivacyLevel: 'mask-user-input'` — form values never recorded |
| Service | `finance-frontend` — appears in RUM > Applications |

#### Finance-specific RUM actions (already instrumented in the dashboard)

The dashboard JS calls `appLog()` which is wired to emit structured console events. After enabling RUM, replace `appLog()` calls with `DD_RUM.addAction()` to surface Finance-domain actions in RUM:

| Action | Trigger | Tags to add |
|---|---|---|
| `payment.initiated` | `POST /v1/payments` success | `amount_bucket`, `currency` |
| `balance.checked` | `GET /v1/accounts/{id}/balance` | `account_tier` |
| `login.success` | Keycloak token issued | `role` |
| `payment.validated` | Compliance role approves/rejects | `decision` |

#### PII cardinality warning

Never pass raw `account_id`, `payment_id`, or exact amounts as RUM action attributes — use bucketed values:
```javascript
amount_bucket: amount < 100 ? '<100' : amount < 1000 ? '100-1000' : '>1000'
```

**Validate:** RUM → Applications → `finance-frontend` → Sessions → click any session → Session Replay available.

Docs: https://docs.datadoghq.com/real_user_monitoring/browser/

### Step 9 — Database Monitoring (PostgreSQL)

DBM is Agent-side only — no application code changes.

#### 9a. Create the monitoring user (run once as superuser)

```sql
-- Run on the 'ledger' database
-- Replace <your-dbm-password> with a password of your choice.
-- Set the same value as DATADOG_DBM_PASSWORD in .env before running 'make create-dd-secret'.
-- Unlike other app credentials (postgres, artemis, keycloak) this password is NOT pre-configured
-- in 02-secrets.yaml — you must choose it yourself.
CREATE USER datadog WITH PASSWORD '<your-dbm-password>';
GRANT pg_monitor TO datadog;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

The full SQL is in the header of `deploy/kubernetes/datadog/checks/postgres-check.yaml`.

#### 9b. Apply the Agent check ConfigMap

```bash
kubectl apply -f deploy/kubernetes/datadog/checks/postgres-check.yaml
```

The ConfigMap is already applied by `make deploy-k8s-dd`. Ensure `dbm-password` is set in the `datadog-secret` (via `make create-dd-secret`).

**Validate:** Databases → Query Metrics — queries from `postgres-ledger` appear.

### Step 10 — ActiveMQ JMX metrics

```bash
kubectl apply -f deploy/kubernetes/datadog/checks/activemq-check.yaml
```

Already applied by `make deploy-k8s-dd`.

**Validate:** Infrastructure → Metrics → search `activemq.queue.size`

### Step 11 — Datadog Terraform resources

```bash
# dd-secrets exports TF_VAR_datadog_api_key + TF_VAR_datadog_app_key.
# Priority: AWS Secrets Manager (if an SSO session is active AND the secrets exist),
# otherwise DD_API_KEY / DD_APP_KEY from .env — so this works locally even while
# logged into AWS.
eval "$(make dd-secrets)"
make tf-apply-dd
```

Resources created:

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
| Dashboard | Finance App overview (APM, DogStatsD, DBM, ActiveMQ) |
| **Synthetic tests** | See Step 12 |
| **4 Security monitors** | See Step 13 |

**Validate:** [Dashboards](https://app.datadoghq.com/dashboard/list) → search `Finance App`

### Step 12 — Synthetic Monitoring

Nine API tests generated from **real observed traffic** (APM span aggregation on `env:staging`):

| Observed baseline | p95 |
|---|---|
| `GET /health` (all services) | < 6ms |
| `GET /v1/accounts/{id}/balance` | 16ms |
| `POST /v1/payments` | 24ms |
| `POST /v1/accounts` | **575ms** ⚠️ (cold connection pool) |

#### Test inventory

| # | File | Test | Tier |
|---|---|---|---|
| 1 | `synthetics/health-check.yaml` | Health check — all services | Critical |
| 2 | `synthetics/payment-flow.yaml` | Payment happy path (POST → GET) | Critical |
| 3 | `synthetics/balance-check.yaml` | Authenticated balance check | Critical |
| 4 | `synthetics/unauthenticated-rejection.yaml` | No token → 401 | Security |
| 5 | `synthetics/payment-bad-payload.yaml` | Bad payload → 422 (not 500) | Negative |
| 6 | `synthetics/account-not-found.yaml` | Missing account → 404 | Negative |
| 7 | `synthetics/account-creation-latency.yaml` | Latency baseline (p95=575ms) | Latency |

Deployed via `make tf-apply-dd` (as `datadog_synthetics_test` Terraform resources).

**Synthetic → APM correlation:** every test request carries `x-datadog-trace-id` automatically. Click **"View Trace"** in any test result to jump to the full APM waterfall.

Docs: https://docs.datadoghq.com/synthetics/apm/

### Step 13 — Application Security (ASM) + Cloud Security (CWS / CSPM)

**Enabled by:** the Agent — `make deploy-k8s-dd` applies `datadog-agent.yaml` with these features on, and the Admission Controller auto-injects `DD_APPSEC_ENABLED=true`. **No `make instrument` and no application code changes.**

All security features are enabled in `deploy/kubernetes/datadog/agent/datadog-agent.yaml` — no application code changes required beyond `DD_APPSEC_ENABLED=true` (set automatically by the Admission Controller when `asm.threats.enabled: true`).

#### What is enabled

| Product | Layer | Detects |
|---|---|---|
| **ASM Threats** | APM tracer (app-side) | SQLi, XSS, SSRF, credential stuffing, business-logic attacks |
| **ASM SCA** | Agent-side | Known CVEs in Python / Java / Node.js / Go dependencies |
| **CWS** | Agent eBPF (kernel) | Shell spawned in container, file writes, privilege escalation, syscall anomalies |
| **CSPM** | Agent + cloud APIs | Privileged pods, exposed secrets, insecure RBAC, CIS / PCI-DSS findings |

#### Agent configuration (already set)

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

#### Verify

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

#### Terraform monitors (deployed via `make tf-apply-dd`)

| Monitor | Condition |
|---|---|
| `asm_high_severity_attacks` | > 10 high-severity AppSec signals in 5m |
| `asm_brute_force` | > 20 login failures in 5m |
| `cws_critical_signal` | Any critical CWS signal in `kube_namespace:finance` |
| `cspm_critical_findings` | Any critical misconfiguration in 1h |

Docs:
- ASM: https://docs.datadoghq.com/security/application_security/
- CWS: https://docs.datadoghq.com/security/cloud_workload_security/
- CSPM: https://docs.datadoghq.com/security/cloud_security_management/misconfigurations/

---

## Traffic Generator

The `traffic-generator` Deployment runs inside the cluster and generates continuous realistic load. It starts automatically with `make deploy-k8s` and requires no laptop involvement.

```bash
# Watch live output
kubectl logs -n finance deploy/traffic-generator -f

# Pause / resume
kubectl scale deployment traffic-generator --replicas=0 -n finance
kubectl scale deployment traffic-generator --replicas=1 -n finance

# Tune rate (requests per second)
kubectl set env deployment/traffic-generator TRAFFIC_RATE=5 -n finance
```

The script (`scripts/generate-traffic.py`) is loaded as a ConfigMap and talks to services via ClusterIP DNS — works identically on local k3s and EKS with no NodePort or port-forward required.

---

## Teardown

```bash
make teardown
```

Removes in order:
1. Any stray `kubectl port-forward` processes (from `make test` / `make test-traffic`)
2. `finance` namespace — all pods, services, ConfigMaps, PVCs (PostgreSQL and Redis data gone)
3. `datadog` namespace — Agent DaemonSet, Cluster Agent, Operator
4. Datadog Operator Helm release
5. Orphaned Docker volumes (`postgres-data`, `redis-data`, `artemis-data`, `keycloak-data`) — only relevant if you previously ran a Docker Compose stack; harmless no-op otherwise

> **K8s data:** PVCs are deleted with the namespace — no separate step needed.

Start fresh:
```bash
make build && make deploy-k8s && make deploy-k8s-dd
```

---

## Makefile targets

| Target | What it does |
|---|---|
| `make build` | Build all 6 service images locally via `docker build` |
| `make build-ecr` | Build for `linux/amd64` and push to ECR (EKS) |
| `make deploy-k8s` | Deploy app + traffic-generator to local k3s |
| `make create-dd-secret` | Create/update `datadog-secret` — auto-detects local (`.env`) vs EKS (Secrets Manager) |
| `make deploy-k8s-dd` | Deploy Datadog Agent (Operator + DaemonSet + checks + security) |
| `make deploy-k8s-eks` | Deploy to EKS using Kustomize overlay (ECR images + LoadBalancer) |
| `make undeploy-k8s` | Remove finance + datadog namespaces |
| `make teardown` | Full reset — namespaces (+ PVCs), Helm release, stray port-forwards, orphaned Docker volumes |
| `make instrument` | Uncomment Layer 2 (5 services + frontend RUM) via patches; injects RUM credentials from Terraform. **Run `make tf-apply-dd` first** so RUM credentials exist (backend patches apply either way) |
| `make uninstrument` | Reverse all Layer 2 patches; restores RUM placeholder tokens |
| `make test` | Run e2e test suite from laptop — requires active port-forwards (see note below) |
| `make test-traffic` | Run traffic generator from laptop — requires active port-forwards (see note below) |
| `make tf-apply-dd` | Apply Datadog Terraform resources (monitors, SLOs, dashboard, synthetics) |
| `make tf-destroy-dd` | Destroy Datadog Terraform resources |
| `make tf-plan-aws` | Plan AWS EKS infrastructure |
| `make tf-apply-aws` | Provision AWS EKS infrastructure (~15–20 min) |
| `make tf-configure-kubectl` | Update kubeconfig for EKS |
| `make tf-destroy-aws` | Destroy all AWS resources (handles ELB, node groups, ECR in order) |
| `make dd-secrets` | Print `eval`-ready `TF_VAR_*` exports — from AWS Secrets Manager (EKS) or `.env` (local fallback) |

> **Port-forward note:** `make test` and `make test-traffic` connect to services from your laptop. `scripts/port-forward.sh` was removed — start port-forwards manually before running these:
> ```bash
> kubectl port-forward svc/gateway-api 8080:8080 -n finance &
> kubectl port-forward svc/account-service 8081:8081 -n finance &
> kubectl port-forward svc/transaction-service 8082:8082 -n finance &
> kubectl port-forward svc/keycloak 8089:8080 -n finance &
> ```
> The in-cluster `traffic-generator` Deployment generates continuous traffic automatically — no port-forward needed for Datadog telemetry.

---

## Troubleshooting

> For a broader, layer-by-layer diagnostic model (useful when it's unclear which of these sections even applies), see [TROUBLESHOOTING.md](./TROUBLESHOOTING.md).

### Admission Controller injection not working

```bash
# Init containers present?
kubectl get pod -n finance -l app=gateway-api \
  -o jsonpath='{.items[0].spec.initContainers[*].name}'
# Expected: datadog-lib-python-init datadog-init-apm-inject

# Required label on pod?
kubectl get pod -n finance -l app=gateway-api \
  -o jsonpath='{.items[0].metadata.labels.admission\.datadoghq\.com/enabled}'
# Expected: true

# Webhook registered?
kubectl get mutatingwebhookconfigurations datadog-webhook \
  -o jsonpath='{.webhooks[?(@.name=="datadog.webhook.lib.injection")].objectSelector}'
```

Common causes:
- **Label missing** — pod template lacks `admission.datadoghq.com/enabled: "true"`
- **Operator not watching the namespace** — check `watchNamespaces` in Helm values
- **Webhook not reconciled** — `kubectl logs -n datadog deploy/datadog-cluster-agent | grep -i admission`

### APM — service not appearing in catalog

1. Confirm `DD_AGENT_HOST` is set to `status.hostIP` (the DaemonSet node agent).
2. Check agent reachability: `kubectl exec -n finance deploy/gateway-api -- wget -qO- http://$DD_AGENT_HOST:8126/info`
3. Java: confirm init container ran — `kubectl get pod -o jsonpath='{.spec.initContainers[*].name}'`
4. Check traces are reaching the agent: `kubectl exec -n datadog daemonset/datadog-agent -c trace-agent -- agent status | grep "Traces received"`

### Agent integration checks failing

```bash
kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent status
# 'no valid instances'       → check YAML in deploy/kubernetes/datadog/checks/
# 'pg_stat_statements error' → run the SQL setup in Step 9a
# 'authentication failed'    → verify dbm-password in the datadog-secret
```

### `make instrument` patch failure

```bash
make uninstrument   # restore clean state (idempotent)
python3 scripts/generate-patches.py
make instrument
```

If source files are in a mixed state, reset with git:
```bash
git checkout HEAD -- \
  gateway-api/main.py \
  fraud-detection/main.py \
  transaction-service/src/index.js \
  notification-service/main.go \
  batch-processor/src/main/java/com/example/finance/batch/listener/DatadogJobListener.java
```

### Traffic generator not producing traces

```bash
# Check the pod is running
kubectl get pod -n finance -l app=traffic-generator

# Check init container completed
kubectl logs -n finance deploy/traffic-generator -c wait-for-services

# Check traffic is flowing
kubectl logs -n finance deploy/traffic-generator --tail=20
```

---

## Validated state

Last validated: local Kubernetes (Colima + k3s, single-node, Apple Silicon) and AWS EKS (Bottlerocket nodes, Terraform-provisioned)

| Signal | Layer | Status |
|---|---|---|
| APM — `gateway-api` | Layer 1 (injection) | ✅ `ddtrace 4.10.5`, traces flowing |
| APM — `account-service` | Layer 1 (injection) | ✅ Java agent injected |
| APM — `transaction-service` | Layer 1 (injection) | ✅ `dd-trace` via `NODE_OPTIONS` |
| APM — `fraud-detection` | Layer 1 (injection) | ✅ `ddtrace` injected |
| APM — `notification-service` | Layer 1 (injection) | ✅ Go tracer injected |
| APM — `batch-processor` | Layer 1 (injection) | ✅ Java agent injected |
| Custom spans | Layer 2 (patch) | ✅ after `make instrument` + rebuild |
| DogStatsD metrics | Layer 2 (patch) | ✅ `finance.payment.initiated` flowing |
| Browser RUM | Layer 2 (patch) + Terraform | ✅ after `make tf-apply-dd` + `make instrument` + frontend restart |
| Log collection | Agent | ✅ `kube_namespace:finance` logs in Datadog |
| Log–trace correlation | Layer 1 | ✅ `dd.trace_id` in every log line |
| Traffic generator | In-cluster | ✅ continuous load, no laptop required |
| Keycloak 26.0 | ClusterIP proxied via nginx HTTPS (:30443, self-signed cert) | ✅ admin console + finance realm users |
| `KEYCLOAK_PUBLIC_URL` | `01-config.yaml` | ✅ `https://localhost:30443` (local) — patch to NLB hostname on EKS |
| Service Catalog | API registration | ✅ 6 services registered (v3 schema) |
| DBM — PostgreSQL | Agent check | ✅ query metrics + samples |
| ActiveMQ JMX | Agent check | ✅ broker + queue metrics |
| Datadog Terraform | `tf-apply-dd` | ✅ 7 monitors, 3 SLOs, dashboard |
| Synthetic tests | `tf-apply-dd` | ✅ tests generated from APM traffic analysis |
| ASM Threats | `DD_APPSEC_ENABLED=true` + Agent | ✅ all 6 services |
| ASM SCA | Agent `asm.sca.enabled: true` | ✅ OSS vulnerability scanning |
| CWS | Agent `cws.enabled: true` | ✅ 3/3 self-tests passed |
| CSPM | Agent `cspm.enabled: true` | ✅ sending to cspm-intake |
| Security monitors | `tf-apply-dd` | ✅ 4 monitors (ASM × 2, CWS × 1, CSPM × 1) |

---

## Key references

| Topic | URL |
|---|---|
| Single-step instrumentation | https://docs.datadoghq.com/tracing/trace_collection/automatic_instrumentation/single-step-apm/ |
| Admission Controller | https://docs.datadoghq.com/containers/cluster_agent/admission_controller/ |
| Unified Service Tagging | https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/ |
| APM setup | https://docs.datadoghq.com/tracing/trace_collection/ |
| Custom instrumentation | https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/ |
| Log correlation | https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/ |
| Custom metrics (DogStatsD) | https://docs.datadoghq.com/developers/dogstatsd/ |
| Continuous Profiler | https://docs.datadoghq.com/profiler/ |
| Database Monitoring | https://docs.datadoghq.com/database_monitoring/ |
| DBM — PostgreSQL self-hosted | https://docs.datadoghq.com/database_monitoring/setup_postgres/selfhosted/ |
| DBM + APM correlation | https://docs.datadoghq.com/database_monitoring/connect_dbm_and_apm/ |
| Data Streams Monitoring | https://docs.datadoghq.com/data_streams/ |
| Data Jobs Monitoring | https://docs.datadoghq.com/data_jobs/ |
| ActiveMQ integration | https://docs.datadoghq.com/integrations/activemq/ |
| Browser RUM | https://docs.datadoghq.com/real_user_monitoring/browser/ |
| RUM Session Replay | https://docs.datadoghq.com/real_user_monitoring/session_replay/ |
| RUM Privacy / PII masking | https://docs.datadoghq.com/real_user_monitoring/session_replay/privacy_options/ |
| Synthetic Monitoring | https://docs.datadoghq.com/synthetics/ |
| Synthetic API tests | https://docs.datadoghq.com/synthetics/api_tests/ |
| Synthetic → APM correlation | https://docs.datadoghq.com/synthetics/apm/ |
| Continuous Testing (CI/CD) | https://docs.datadoghq.com/continuous_testing/cicd_integrations/ |
| Application Security (ASM) | https://docs.datadoghq.com/security/application_security/ |
