# Finance Sample App — Instrumentation Guide

Two complementary instrumentation layers — both independent, both reversible:

| Layer | What it does | How |
|---|---|---|
| **1 — Single-step (Admission Controller)** | Injects the Datadog tracer into every pod at startup — no code changes, no rebuilds | `admission.datadoghq.com/enabled: "true"` label + Operator webhook |
| **2 — Manual (`make instrument`)** | Adds custom business spans, Finance-domain tags, and DogStatsD metrics | Unified diff patches — fully reversible with `make uninstrument` |

Layer 1 alone gives distributed tracing, log correlation, and runtime metrics out of the box. Layer 2 enriches it with business context.

---

## TL;DR

```bash
# 1. Build and deploy the app (traffic starts automatically)
make build
# On Docker Desktop / Rancher Desktop: images are available immediately — no extra step.
# On kind/k3d/minikube: load images first — see README.md Prerequisites.
make deploy-k8s

# 2. Add Datadog
make create-dd-secret   # reads DD_API_KEY + DD_APP_KEY from .env
make deploy-k8s-dd      # Operator + DaemonSet + Cluster Agent + ASM/CWS/CSPM

# 3. Watch traces appear (no code changes needed)
kubectl logs -n finance deploy/traffic-generator -f
# → Open https://app.datadoghq.com/apm/services (filter: env:staging)

# 4. Optional: add custom spans + DogStatsD metrics (Layer 2)
make instrument
make build
# Docker Desktop / Rancher Desktop: images available immediately after build
# kind:     kind load docker-image finance-sample-app-<svc>:latest
# k3d:      k3d image import finance-sample-app-<svc>:latest
# minikube: minikube image load finance-sample-app-<svc>:latest
kubectl rollout restart deployment -n finance

# 5. Reverse Layer 2 at any time
make uninstrument && make build   # then reload (if needed) + rollout restart

# 6. Apply Terraform resources (monitors, SLOs, dashboard, 9 synthetic tests)
eval "$(make dd-secrets)"   # EKS only — or export TF_VAR_* manually
make tf-apply-dd
```

---

## Prerequisites

### Datadog credentials — K8s Secret

Three keys are stored in a single K8s Secret (`datadog-secret` in the `datadog` namespace):

| Key | Used by | Where to get it |
|---|---|---|
| `api-key` | Datadog Agent (DaemonSet auth) | https://app.datadoghq.com/organization-settings/api-keys |
| `app-key` | Terraform (`tf-apply-dd`), catalog registration | https://app.datadoghq.com/organization-settings/application-keys |
| `dbm-password` | DBM Agent check (PostgreSQL read-only user) | Set when creating the monitoring user |

#### Option A — `make create-dd-secret` (recommended)

Auto-detects local vs EKS and creates the secret in one command:

```bash
make create-dd-secret
```

**Local (Docker Desktop / kind / k3d / minikube):** reads from `.env` at the project root:
```bash
cp .env.example .env
# edit .env — set DD_API_KEY and DD_APP_KEY
make create-dd-secret
```

**EKS:** fetches from AWS Secrets Manager automatically (requires a valid SSO session):
```bash
aws sso login --profile partner
make create-dd-secret   # pulls from finance-app/staging/dd-{api,app}-key
```

Idempotent — safe to re-run to rotate keys.

#### Option B — kubectl literals

```bash
kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic datadog-secret \
  --from-literal api-key="<YOUR_DD_API_KEY>" \
  --from-literal app-key="<YOUR_DD_APP_KEY>" \
  --from-literal dbm-password="<YOUR_DBM_PASSWORD>" \
  --namespace datadog \
  --dry-run=client -o yaml | kubectl apply -f -
```

#### Option C — External Secrets Operator (GitOps / production)

An `ExternalSecret` manifest is in `deploy/kubernetes/datadog/secrets/datadog-secrets.yaml`. It pulls from AWS Secrets Manager, GCP Secret Manager, or Vault and keeps the secret in sync.

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace
kubectl apply -f deploy/kubernetes/datadog/secrets/datadog-secrets.yaml
```

Docs: https://external-secrets.io/

#### Verify the secret

```bash
kubectl get secret datadog-secret -n datadog \
  -o jsonpath='{.data}' | python3 -m json.tool
# Expected keys: api-key, app-key, dbm-password (base64-encoded — correct)
```

### Datadog Operator

```bash
helm repo add datadog https://helm.datadoghq.com
helm install datadog-operator datadog/datadog-operator \
  --namespace datadog --create-namespace \
  --set watchNamespaces='{datadog,finance}'

make create-dd-secret
make deploy-k8s-dd
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
  admission.datadoghq.com/python-lib.version: latest   # gateway-api, fraud-detection
  admission.datadoghq.com/js-lib.version: latest       # transaction-service
  admission.datadoghq.com/java-lib.version: latest     # account-service, batch-processor
  admission.datadoghq.com/go-lib.version: latest       # notification-service
```

Both are already set in all six service manifests under `deploy/kubernetes/base/services/`.

### What gets injected

| Service | Library | Injection mechanism |
|---|---|---|
| `gateway-api` | `ddtrace` (Python) | `PYTHONPATH` + auto-instrumentation |
| `fraud-detection` | `ddtrace` (Python) | same |
| `transaction-service` | `dd-trace` (Node.js) | `NODE_OPTIONS=--require dd-trace/init` |
| `account-service` | `dd-java-agent` (Java) | `JAVA_TOOL_OPTIONS=-javaagent:...` |
| `batch-processor` | `dd-java-agent` (Java) | same |
| `notification-service` | `dd-trace-go` (Go) | orchestrion at init |

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

---

## Layer 2 — Manual instrumentation (`make instrument`)

Applies unified diff patches to five services, uncommenting custom spans and DogStatsD metrics. Fully reversible with `make uninstrument`.

### What each patch adds

| Service | What gets uncommented |
|---|---|
| `gateway-api` | `tracer.trace("payment.authorize")`, `tracer.trace("account.balance_check")`, `statsd.increment("finance.payment.initiated")`, `statsd.histogram("finance.payment.processing_time")` |
| `fraud-detection` | `tracer.trace("fraud.score")` with `fraud.score_bucket` tag |
| `transaction-service` | `tracer.startSpan("ledger.commit")` with `transaction.type`, `payment.currency`, `db.instance` tags |
| `notification-service` | `tracer.StartSpanFromContext("alert.send")` with `messaging.destination`, `jms.correlation_id` tags; `profiler.Start()` |
| `batch-processor` | OpenTracing span tags in `DatadogJobListener` (`job.name`, `job.status`, `job.records_processed`) |

`account-service` has no Layer 2 patch — fully covered by the Java agent auto-instrumentation.

### Workflow

```bash
make instrument
make build

# Local — reload images if needed, then rolling-restart
# Docker Desktop / Rancher Desktop: skip the load step (images available automatically)
# kind:     kind load docker-image finance-sample-app-<svc>:latest
# k3d:      k3d image import finance-sample-app-<svc>:latest
# minikube: minikube image load finance-sample-app-<svc>:latest
kubectl rollout restart deployment -n finance

# EKS
make build-ecr && make deploy-k8s-eks
kubectl rollout restart deployment -n finance
```

### Regenerating patches

```bash
make uninstrument                        # uninstrumented state required first
python3 scripts/generate-patches.py     # regenerates all 5 patch files
for p in scripts/patches/*.patch; do
  patch --dry-run -p1 -s --input "$p" && echo "OK: $p" || echo "FAIL: $p"
done
```

---

## Step-by-step breakdown

### Step 1 — Structured JSON logs (always active)

All six services emit structured JSON to stdout. The Agent collects them via the DaemonSet `/var/log/pods/` volume mount. Each pod template carries an autodiscovery annotation:

```yaml
annotations:
  ad.datadoghq.com/gateway-api.logs: '[{"source":"python","service":"gateway-api"}]'
```

Already set in all six service manifests — no action required.

**Validate:** Log Explorer → `kube_namespace:finance`

---

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

---

### Step 3 — APM traces (Layer 1, automatic)

Traces appear automatically once the Admission Controller injects the tracer. No code changes required.

**Validate:** APM → Services — all six services appear within ~2 minutes of the first request.

To add custom business spans:
```bash
make instrument && make build   # then reload + rollout restart
```

---

### Step 4 — Log–trace correlation (automatic with Layer 1)

The injected tracer patches the logging framework to append `dd.trace_id` and `dd.span_id` to every log line. No code changes required.

**Validate:** Log Explorer → click any log from a finance service → "View Trace" button appears.

---

### Step 5 — Custom spans (Layer 2)

```bash
make instrument
make build   # then reload images + rollout restart
```

After rebuild, custom spans appear in APM:
- `payment.authorize` (gateway-api)
- `account.balance_check` (gateway-api)
- `fraud.score` (fraud-detection)
- `ledger.commit` (transaction-service)
- `alert.send` (notification-service)
- `job.name` / `job.status` tags on batch spans (batch-processor)

**Validate:** APM → Traces → filter by `resource_name:payment.authorize`

---

### Step 6 — Custom metrics (Layer 2, DogStatsD)

Enabled by the same `make instrument` patches:

| Metric | Type | Tags |
|---|---|---|
| `finance.payment.initiated` | Counter | `transaction.type`, `currency` |
| `finance.payment.processing_time` | Histogram | `transaction.type` |
| `finance.fraud.score` | Gauge | `score_bucket` |

**Validate:** Metrics Explorer → search `finance.payment.initiated`

---

### Step 7 — Continuous Profiler (Layer 1)

The Agent-side profiler intake is enabled automatically when `DD_PROFILING_ENABLED=true` is set on a pod. Add it to any service manifest's env block:

```yaml
- name: DD_PROFILING_ENABLED
  value: "true"
```

For Java: add `-Ddd.profiling.enabled=true` to `JAVA_TOOL_OPTIONS`.

**Validate:** APM → Profiles — flame graphs appear within ~1 minute.

---

### Step 8 — Database Monitoring (PostgreSQL)

DBM is Agent-side only — no application code changes.

#### 8a. Create the monitoring user (run once as superuser)

```sql
-- Run on the 'ledger' database
CREATE USER datadog WITH PASSWORD '<your-dbm-password>';
GRANT pg_monitor TO datadog;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

The full SQL is in the header of `deploy/kubernetes/datadog/checks/postgres-check.yaml`.

#### 8b. Apply the Agent check ConfigMap

```bash
kubectl apply -f deploy/kubernetes/datadog/checks/postgres-check.yaml
```

The ConfigMap is already applied by `make deploy-k8s-dd`. Ensure `dbm-password` is set in the `datadog-secret` (via `make create-dd-secret`).

**Validate:** Databases → Query Metrics — queries from `postgres-ledger` appear.

---

### Step 9 — ActiveMQ JMX metrics

```bash
kubectl apply -f deploy/kubernetes/datadog/checks/activemq-check.yaml
```

Already applied by `make deploy-k8s-dd`.

**Validate:** Infrastructure → Metrics → search `activemq.queue.size`

---

### Step 10 — Datadog Terraform resources

```bash
eval "$(make dd-secrets)"   # EKS: exports TF_VAR_datadog_api_key + TF_VAR_datadog_app_key
# Local: export manually:
#   export TF_VAR_datadog_api_key=$(grep DD_API_KEY .env | cut -d= -f2)
#   export TF_VAR_datadog_app_key=$(grep DD_APP_KEY .env | cut -d= -f2)
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
| **9 Synthetic tests** | See Step 11 |
| **4 Security monitors** | See Step 12 |

**Validate:** [Dashboards](https://app.datadoghq.com/dashboard/list) → search `Finance App`

---

### Step 11 — Synthetic Monitoring

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

---

### Step 12 — Application Security (ASM) + Cloud Security (CWS / CSPM)

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
1. Any stray `kubectl port-forward` processes
2. `finance` namespace — all pods, services, ConfigMaps, PVCs
3. `datadog` namespace — Agent DaemonSet, Cluster Agent, Operator
4. Datadog Operator Helm release
5. Orphaned Docker volumes (`postgres-data`, `redis-data`, `artemis-data`, `keycloak-data`)

> **K8s data:** PVCs are deleted with the namespace — no separate cleanup needed.
> **Docker volumes:** leftover from previous Compose runs — `make teardown` removes them.

Start fresh:
```bash
make build && make deploy-k8s && make create-dd-secret && make deploy-k8s-dd
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
| `make teardown` | Full reset — namespaces + Helm + Docker volumes |
| `make instrument` | Uncomment all Layer 2 instrumentation across 5 services |
| `make uninstrument` | Re-comment all Layer 2 instrumentation |
| `make test` | Run e2e test suite from laptop (requires `kubectl port-forward`) |
| `make test-traffic` | Run traffic generator from laptop (requires `kubectl port-forward`) |
| `make tf-apply-dd` | Apply Datadog Terraform resources (monitors, SLOs, dashboard, synthetics) |
| `make tf-destroy-dd` | Destroy Datadog Terraform resources |
| `make tf-plan-aws` | Plan AWS EKS infrastructure |
| `make tf-apply-aws` | Provision AWS EKS infrastructure (~15–20 min) |
| `make tf-configure-kubectl` | Update kubeconfig for EKS |
| `make tf-destroy-aws` | Destroy all AWS resources (handles ELB, node groups, ECR in order) |
| `make dd-secrets` | Print `eval`-ready `TF_VAR_*` exports from Secrets Manager (EKS) |

---

## Troubleshooting

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
# 'pg_stat_statements error' → run the SQL setup in Step 8a
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

Last validated: Docker Desktop with Kubernetes enabled (single-node, Apple Silicon)

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
| Log collection | Agent | ✅ `kube_namespace:finance` logs in Datadog |
| Log–trace correlation | Layer 1 | ✅ `dd.trace_id` in every log line |
| Traffic generator | In-cluster | ✅ continuous load, no laptop required |
| Service Catalog | API registration | ✅ 6 services registered (v3 schema) |
| DBM — PostgreSQL | Agent check | ✅ query metrics + samples |
| ActiveMQ JMX | Agent check | ✅ broker + queue metrics |
| Datadog Terraform | `tf-apply-dd` | ✅ 7 monitors, 3 SLOs, dashboard |
| Synthetic tests | `tf-apply-dd` | ✅ 9 tests from APM traffic analysis |
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
| Synthetic Monitoring | https://docs.datadoghq.com/synthetics/ |
| Synthetic API tests | https://docs.datadoghq.com/synthetics/api_tests/ |
| Synthetic → APM correlation | https://docs.datadoghq.com/synthetics/apm/ |
| Continuous Testing (CI/CD) | https://docs.datadoghq.com/continuous_testing/cicd_integrations/ |
| Application Security (ASM) | https://docs.datadoghq.com/security/application_security/ |
| ASM — enabling | https://docs.datadoghq.com/security/application_security/enabling/ |
| Cloud Workload Security (CWS) | https://docs.datadoghq.com/security/cloud_workload_security/ |
| CSM Misconfigurations (CSPM) | https://docs.datadoghq.com/security/cloud_security_management/misconfigurations/ |
| Tagging best practices | https://docs.datadoghq.com/tagging/assigning_tags/ |
| Trace data security (PII) | https://docs.datadoghq.com/tracing/configure_data_security/ |
| Datadog Operator | https://github.com/DataDog/datadog-operator |
| Helm charts | https://github.com/DataDog/helm-charts |
| Agent config reference | https://github.com/DataDog/datadog-agent/blob/main/pkg/config/config_template.yaml |
