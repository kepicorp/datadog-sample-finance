# Finance Sample App — Instrumentation Guide

This guide explains how observability is enabled on the finance sample app
running on Kubernetes. There are two complementary layers:

| Layer | What it does | How |
|---|---|---|
| **1 — Single-step (Admission Controller)** | Automatically injects the Datadog tracer library into every pod at startup — no code changes, no image rebuilds | `admission.datadoghq.com/enabled: "true"` pod label + Operator webhook |
| **2 — Manual instrumentation** | Adds custom spans, Finance-domain span tags, and DogStatsD metrics on top of the auto-instrumented baseline | `make instrument` / `make uninstrument` |

Both layers are independent. Layer 1 gives you full distributed tracing and log
correlation out of the box. Layer 2 enriches it with business context.

---

## TL;DR

```bash
# 1. Deploy the app (uninstrumented images — Layer 1 handles tracing)
make deploy-k8s

# 2. Deploy the Datadog Agent (Operator + DaemonSet + Admission Controller)
make deploy-k8s-dd

# 3. Generate traffic — traces appear automatically via single-step injection
python3 scripts/generate-traffic.py --rate 3 --duration 60

# 4. (Optional) Add custom spans + metrics on top
make instrument
make build
# Load images into k3s and rolling-restart:
for svc in gateway-api account-service transaction-service fraud-detection notification-service batch-processor; do
  docker save finance-sample-app-$svc:latest | colima ssh -- sudo ctr image import -
done
kubectl rollout restart deployment -n finance

# 5. Reverse Layer 2 at any time (Layer 1 tracing continues)
make uninstrument
make build && # reload + restart as above
```

---

## Prerequisites

### Datadog API key

The secret must exist in the `datadog` namespace before deploying the Agent:

```bash
kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic datadog-secret \
  --from-literal api-key="<YOUR_DD_API_KEY>" \
  --namespace datadog \
  --dry-run=client -o yaml | kubectl apply -f -
```

On EKS the key is fetched from AWS Secrets Manager automatically by
`make deploy-k8s-dd`. For local k3s, set it once as above.

### Datadog Operator

```bash
# Install once per cluster
helm repo add datadog https://helm.datadoghq.com
helm install datadog-operator datadog/datadog-operator \
  --namespace datadog --create-namespace \
  --set watchNamespaces='{datadog,finance}'

# Then deploy the Agent DaemonSet + Cluster Agent
make deploy-k8s-dd
```

---

## Layer 1 — Single-step instrumentation (Admission Controller)

The Datadog Operator's **mutating admission webhook** injects the tracer
library into pods at creation time via an init container. No changes to
application code or Docker images are required.

### How it's enabled

Two things must be set on each application pod:

**1. Pod label** — tells the webhook to process this pod:
```yaml
labels:
  admission.datadoghq.com/enabled: "true"
```

**2. Language annotation** — tells the webhook which library to inject:
```yaml
annotations:
  admission.datadoghq.com/python-lib.version: latest   # gateway-api, fraud-detection
  admission.datadoghq.com/js-lib.version: latest       # transaction-service
  admission.datadoghq.com/java-lib.version: latest     # account-service, batch-processor
  admission.datadoghq.com/go-lib.version: latest       # notification-service
```

Both are already set in `deploy/kubernetes/base/services/<name>.yaml` for all
six services.

### What gets injected

When a pod with those labels is created, the webhook adds an init container
(`datadog-lib-<lang>-init`) that copies the tracer library into the pod's
filesystem, then sets environment variables so the runtime loads it
automatically:

| Service | Injected library | Mechanism |
|---|---|---|
| `gateway-api` | `ddtrace` (Python) | `PYTHONPATH` + auto-instrumentation |
| `fraud-detection` | `ddtrace` (Python) | same |
| `transaction-service` | `dd-trace` (Node.js) | `NODE_OPTIONS=--require dd-trace/init` |
| `account-service` | `dd-java-agent` (Java) | `JAVA_TOOL_OPTIONS=-javaagent:...` |
| `batch-processor` | `dd-java-agent` (Java) | same |
| `notification-service` | `dd-trace-go` (Go) | compile-time via orchestrion in init |

The injected agent also sets `DD_TRACE_AGENT_URL`, `DD_SERVICE`,
`DD_ENV`, `DD_VERSION`, and `DD_INSTRUMENTATION_INSTALL_TYPE=k8s_lib_injection`
automatically.

### Verifying injection

```bash
# Check init containers were added by the webhook
kubectl get pod -n finance -l app=gateway-api \
  -o jsonpath='{.items[0].spec.initContainers[*].name}'
# Expected: datadog-lib-python-init datadog-init-apm-inject

# Confirm ddtrace version inside the running pod
kubectl exec -n finance deploy/gateway-api -- \
  python3 -c "import ddtrace; print(ddtrace.__version__)"

# Confirm instrumentation type env var
kubectl exec -n finance deploy/gateway-api -- \
  env | grep DD_INSTRUMENTATION_INSTALL_TYPE
# Expected: DD_INSTRUMENTATION_INSTALL_TYPE=k8s_lib_injection
```

---

## Layer 2 — Manual instrumentation (`make instrument`)

`make instrument` applies unified diff patches to five services in one
command, adding custom business spans and DogStatsD metrics on top of
the baseline auto-instrumentation provided by Layer 1.
`make uninstrument` reverses all patches cleanly.

### What each patch adds

| Service | What gets uncommented |
|---|---|
| `gateway-api` | `tracer.trace("payment.authorize")`, `tracer.trace("account.balance_check")`, `statsd.increment("finance.payment.initiated")`, `statsd.histogram("finance.payment.processing_time")`; adds `ddtrace==2.9.0` + `datadog==0.49.1` to `requirements.txt` |
| `fraud-detection` | `tracer.trace("fraud.score")` with `fraud.score_bucket` tag; adds `ddtrace[data_streams]==2.9.0` |
| `transaction-service` | `tracer.startSpan("ledger.commit")` with `transaction.type`, `payment.currency`, `db.instance` tags; adds `dd-trace: ^5.0.0` to `package.json` |
| `notification-service` | `tracer.StartSpanFromContext("alert.send")` with `messaging.destination`, `jms.correlation_id` tags; `profiler.Start()`; activates `require` block in `go.mod` |
| `batch-processor` | OpenTracing span tags in `DatadogJobListener` (`job.name`, `job.status`, `job.records_processed`); adds `opentracing-api:0.33.0` + `opentracing-util:0.33.0` to `build.gradle` |

`account-service` has no Layer 2 patch — it's fully covered by the Java
agent auto-instrumentation from Layer 1.

### Workflow after `make instrument`

Because Layer 2 adds library dependencies (e.g. `ddtrace==2.9.0` to
`requirements.txt`), you need to rebuild images after patching:

```bash
make instrument
make build

# Local k3s — load images and rolling-restart
for svc in gateway-api account-service transaction-service fraud-detection notification-service batch-processor; do
  docker save finance-sample-app-$svc:latest | colima ssh -- sudo ctr image import -
done
kubectl rollout restart deployment -n finance

# EKS
make build-ecr
make deploy-k8s-eks
```

### Regenerating patches

If you modify any instrumented source file, regenerate patches from
the uninstrumented state:

```bash
make uninstrument                       # must be uninstrumented first
python3 scripts/generate-patches.py    # regenerates all 5 patch files
# verify
for p in scripts/patches/*.patch; do
  patch --dry-run -p1 -s --input "$p" && echo "OK: $p" || echo "FAIL: $p"
done
```

---

## Step-by-step breakdown

### Step 1 — Structured JSON logs (always active)

All six services log in structured JSON to stdout. The Datadog Agent
collects them from `/var/log/pods/` via the DaemonSet volume mount.

Each service's pod template has an autodiscovery annotation that sets
the correct `source` and `service`:

```yaml
annotations:
  ad.datadoghq.com/gateway-api.logs: '[{"source":"python","service":"gateway-api"}]'
```

Already set in all six `deploy/kubernetes/base/services/<name>.yaml` files —
no action required.

**Validate:** Log Explorer → `kube_namespace:finance`

---

### Step 2 — Unified Service Tags (always active)

`DD_ENV`, `DD_SERVICE`, `DD_VERSION`, and `DD_AGENT_HOST` are set in
each service's deployment via the pod spec env block:

```yaml
- name: DD_ENV
  value: "staging"
- name: DD_SERVICE
  value: "gateway-api"
- name: DD_VERSION
  value: "latest"
- name: DD_AGENT_HOST       # points to the DaemonSet agent on the same node
  valueFrom:
    fieldRef:
      fieldPath: status.hostIP
```

Already set in all six manifests — no action required.

**Validate:** any log or trace should carry `env:staging service:<name> version:latest`.

---

### Step 3 — APM traces (Layer 1, automatic)

Traces appear automatically once the Admission Controller injects the
tracer library. No code changes or `make instrument` required.

**Validate:** APM → Services — all six services should appear within ~2
minutes of first traffic.

To add custom business spans on top, apply Layer 2:
```bash
make instrument && make build && # reload images + rolling-restart
```

---

### Step 4 — Log–trace correlation (automatic with Layer 1)

The injected tracer patches the logging library to inject `dd.trace_id`
and `dd.span_id` into every log line automatically. The Datadog log
pipeline's trace ID remapper links logs to their parent span.

**Validate:** Log Explorer → open any log from `gateway-api` → look for
`dd.trace_id` attribute → click **View Trace**.

---

### Step 5 — Custom spans (Layer 2)

After `make instrument` + rebuild, these named spans appear in APM:

| Span | Service | Key tags |
|---|---|---|
| `payment.authorize` | `gateway-api` | `transaction.type`, `payment.currency`, `account.id` |
| `account.balance_check` | `gateway-api` | `account.id`, `http.route` |
| `ledger.commit` | `transaction-service` | `transaction.type`, `payment.currency`, `db.instance` |
| `fraud.score` | `fraud-detection` | `fraud.score_bucket`, `account.id` |
| `alert.send` | `notification-service` | `notification.channel`, `jms.correlation_id` |
| Job metadata | `batch-processor` | `job.name`, `job.status`, `job.records_processed` |

**Validate:** APM → Traces → search `resource_name:payment.authorize`

---

### Step 6 — Custom metrics (Layer 2, DogStatsD)

After `make instrument` + rebuild:

| Metric | Type | Service |
|---|---|---|
| `finance.payment.initiated` | counter | `gateway-api` |
| `finance.payment.processing_time` | histogram | `gateway-api` |
| `finance.notification.dispatch_time` | histogram | `notification-service` |
| `finance.notification.sent` | counter | `notification-service` |

Additional metrics are generated in Datadog from APM spans via
`datadog_spans_metric` Terraform resources (no DogStatsD needed):

| Metric | Source |
|---|---|
| `finance.payment.hits` | spans from `gateway-api` |
| `finance.payment.duration` | spans from `gateway-api` |
| `finance.fraud.hits` | spans from `fraud-detection` |
| `finance.batch.records_processed` | spans from `batch-processor` |

Apply with `make tf-apply-dd` (see Step 10).

**Validate:** Metrics Explorer → `finance.*`

---

### Step 7 — Continuous Profiler (Layer 1)

The injected Java agent enables profiling for `account-service` and
`batch-processor` automatically. For Python and Go services, profiling
is uncommented by `make instrument`.

**Validate:** [Continuous Profiler](https://app.datadoghq.com/profiling)

---

### Step 8 — Database Monitoring (PostgreSQL)

DBM is Agent-side — no application code changes needed.

#### 8a. Create the monitoring user (run once)

```bash
# Against the 'ledger' database
kubectl exec -n finance postgres-ledger-0 -- psql -U finance -d ledger <<'SQL'
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

# Also in the 'postgres' system database — the Agent probes all databases
# it can connect to; without this the check logs a WARNING.
kubectl exec -n finance postgres-ledger-0 -- psql -U finance -d postgres \
  -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements SCHEMA public;"
```

#### 8b. Apply the Agent check config

The config is in `deploy/kubernetes/datadog/checks/postgres-check.yaml`
and is applied by `make deploy-k8s-dd`. Edit it to set the correct
password before deploying, or use a K8s Secret reference.

**Validate:** [Databases → Query Metrics](https://app.datadoghq.com/databases)

---

### Step 9 — ActiveMQ JMX metrics

The Agent collects broker metrics via JMX on port 1099. The config is in
`deploy/kubernetes/datadog/checks/activemq-check.yaml` and is applied by
`make deploy-k8s-dd`.

**Requires the `datadog/agent:7-jmx` image** (bundled JRE for JMXFetch).
The `DatadogAgent` CR in `deploy/kubernetes/datadog/agent/datadog-agent.yaml`
already specifies this image.

**Validate:** Metrics Explorer → `activemq.artemis.*`

---

### Step 10 — Datadog Terraform resources

Span metrics, log metrics, monitors, SLOs, and the Finance dashboard are
managed as code in `deploy/terraform/datadog/`.

```bash
# Export credentials from AWS Secrets Manager
eval "$(make dd-secrets)"

# Apply all Datadog resources
make tf-apply-dd
```

Resources created:

| Resource | What it is |
|---|---|
| Log index `finance-logs` | 15-day retention, filter: `kube_namespace:finance` |
| Log pipeline | JSON parser + trace ID remapper + service remapper |
| `finance.payment.hits` | Spans metric from `gateway-api` POST /v1/payments |
| `finance.payment.duration` | Distribution spans metric (p95 latency) |
| `finance.fraud.hits` | Spans metric from `fraud-detection` |
| `finance.batch.records_processed` | Spans metric from `batch-processor` |
| `finance.logs.errors` | Logs metric — error count by service |
| `finance.logs.payments_initiated` | Logs metric — payment events |
| 7 monitors | Pod restarts, error rate, payment latency, payment errors, fraud queue, stuck transactions, pods not running |
| 3 SLOs | Payment availability (99.9%), payment latency (99%), fraud consumer (99.5%) |
| Dashboard | Finance App overview with APM, DogStatsD, DBM, and ActiveMQ widgets |

**Validate:** [Dashboards](https://app.datadoghq.com/dashboard/list) →
search `Finance App`

---

## Makefile targets

| Target | What it does |
|---|---|
| `make deploy-k8s` | Deploy the Finance app to K8s (no Datadog) |
| `make deploy-k8s-dd` | Deploy Datadog Agent (Operator + DaemonSet + checks) |
| `make undeploy-k8s` | Remove all Finance app resources from K8s |
| `make instrument` | Apply all 5 patches (Layer 2 — custom spans + metrics) |
| `make uninstrument` | Reverse all 5 patches |
| `make build` | Build all service images for the local platform |
| `make build-ecr` | Build for `linux/amd64` and push to ECR (EKS) |
| `make tf-apply-dd` | Apply Datadog Terraform resources |
| `make tf-destroy-dd` | Destroy Datadog Terraform resources |
| `make dd-secrets` | Print `eval`-ready `export TF_VAR_*` from Secrets Manager |

---

## Troubleshooting

### Single-step injection not working

```bash
# Check the webhook was called (init containers present?)
kubectl get pod -n finance -l app=gateway-api \
  -o jsonpath='{.items[0].spec.initContainers[*].name}'
# Expected: datadog-lib-python-init datadog-init-apm-inject

# Check pod has the required label
kubectl get pod -n finance -l app=gateway-api \
  -o jsonpath='{.items[0].metadata.labels.admission\.datadoghq\.com/enabled}'
# Expected: true

# Check the webhook exists and targets the finance namespace
kubectl get mutatingwebhookconfigurations datadog-webhook \
  -o jsonpath='{.webhooks[?(@.name=="datadog.webhook.lib.injection")].objectSelector}'
```

Common causes:
- **Label missing** — pod template doesn't have `admission.datadoghq.com/enabled: "true"`
- **Operator not watching the namespace** — check `watchNamespaces` in Helm values
- **Webhook not reconciled** — `kubectl logs -n datadog deploy/datadog-cluster-agent | grep -i admission`

### APM — service not appearing

1. Confirm `DD_AGENT_HOST=<node IP>` is set (use `status.hostIP` fieldRef).
2. Check the agent is reachable: `kubectl exec -n finance deploy/gateway-api -- wget -qO- http://$DD_AGENT_HOST:8126/info`.
3. For Java: confirm the init container ran — `kubectl get pod -o jsonpath='{.spec.initContainers[*].name}'`.

### Agent integration checks failing

```bash
# Check all check statuses
kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent status

# Common issues:
# 'no valid instances' — check YAML in deploy/kubernetes/datadog/checks/
# 'pg_stat_statements not created' — run the SQL in Step 8a
# 'java not found' — agent image must be 7-jmx, not 7
```

### `make instrument` patch failure

```bash
make uninstrument            # restore clean state (safe to run again)
python3 scripts/generate-patches.py   # regenerate from current file state
make instrument
```

If source files are in a mixed state, reset with git:

```bash
git checkout HEAD -- \
  gateway-api/main.py gateway-api/requirements.txt \
  fraud-detection/main.py fraud-detection/requirements.txt \
  transaction-service/src/index.js transaction-service/package.json \
  notification-service/main.go notification-service/go.mod \
  batch-processor/src/main/java/com/example/finance/batch/listener/DatadogJobListener.java \
  batch-processor/build.gradle
```

---

## Validated state

Last validated on local k3s (Colima, single-node):

| Signal | Layer | Status |
|---|---|---|
| APM — `gateway-api` | 1 (injection) | ✅ `ddtrace 4.10.5` injected, traces flowing |
| APM — `account-service` | 1 (injection) | ✅ Java agent injected |
| APM — `transaction-service` | 1 (injection) | ✅ `dd-trace` injected via `NODE_OPTIONS` |
| APM — `fraud-detection` | 1 (injection) | ✅ `ddtrace` injected |
| APM — `notification-service` | 1 (injection) | ✅ Go tracer injected |
| APM — `batch-processor` | 1 (injection) | ✅ Java agent injected |
| Custom spans (`payment.authorize`, etc.) | 2 (patch) | ✅ after `make instrument` + rebuild |
| DogStatsD metrics | 2 (patch) | ✅ `finance.payment.initiated` flowing |
| Log collection | Agent | ✅ `kube_namespace:finance` logs in Datadog |
| Log–trace correlation (`dd.trace_id`) | 1 (injection) | ✅ in every log line |
| DBM — PostgreSQL | Agent check | ✅ query metrics + samples |
| ActiveMQ JMX | Agent check | ✅ 30 broker + queue metrics |
| Datadog Terraform | `tf-apply-dd` | ✅ 7 monitors, 3 SLOs, dashboard |

---

## Key references

| Topic | URL |
|---|---|
| Single-step instrumentation | https://docs.datadoghq.com/tracing/trace_collection/automatic_instrumentation/single-step-apm/ |
| Admission Controller | https://docs.datadoghq.com/containers/cluster_agent/admission_controller/ |
| APM setup | https://docs.datadoghq.com/tracing/trace_collection/ |
| Log correlation | https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/ |
| Custom metrics (DogStatsD) | https://docs.datadoghq.com/developers/dogstatsd/ |
| Continuous Profiler | https://docs.datadoghq.com/profiler/ |
| Database Monitoring | https://docs.datadoghq.com/database_monitoring/ |
| DBM — PostgreSQL self-hosted | https://docs.datadoghq.com/database_monitoring/setup_postgres/selfhosted/ |
| ActiveMQ integration | https://docs.datadoghq.com/integrations/activemq/ |
| Datadog Operator | https://github.com/DataDog/datadog-operator |
| Unified Service Tagging | https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/ |
| Tagging best practices | https://docs.datadoghq.com/tagging/assigning_tags/ |
