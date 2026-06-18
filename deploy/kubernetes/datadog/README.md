# Adding Datadog to the Kubernetes Deployment

This directory contains everything needed to instrument the Finance sample app
with the full Datadog observability stack on Kubernetes.

**Prerequisite:** the base application must already be running:
```bash
make deploy-k8s
kubectl get pods -n finance   # all 11 pods should be Running
```

---

## What is deployed

| Resource | Purpose |
|---|---|
| `agent/datadog-agent.yaml` | `DatadogAgent` CRD — Operator installs Node Agent DaemonSet + Cluster Agent |
| `agent/helm-values.yaml` | Alternative Helm chart values (if not using the Operator) |
| `checks/postgres-check.yaml` | DBM Agent check ConfigMap (all commented out) |
| `checks/activemq-check.yaml` | ActiveMQ JMX Agent check ConfigMap (all commented out) |
| `secrets/datadog-secrets.yaml` | Secret template for the Datadog API key |
| `services/gateway-api-with-datadog.yaml` | gateway-api Deployment with DD_ env vars and Admission Controller annotations |

---

## Step 1 — Install the Datadog Operator

The Datadog Operator manages the Agent DaemonSet and Cluster Agent via a single
`DatadogAgent` CRD. It is the recommended production install path.

```bash
helm repo add datadog https://helm.datadoghq.com
helm repo update

helm install datadog-operator datadog/datadog-operator \
  --namespace datadog \
  --create-namespace \
  --set watchNamespaces="{datadog,finance}"
```

Verify the Operator is running:
```bash
kubectl get pods -n datadog
```

> **Helm alternative:** skip the Operator and use `agent/helm-values.yaml` directly.
> See the [Helm alternative](#helm-alternative-without-the-operator) section below.

---

## Step 2 — Create the Datadog API Key Secret

**Never pass the API key as a plain value.** Create a Kubernetes Secret:

```bash
# Replace <YOUR_DATADOG_API_KEY> with a real key from:
# https://app.datadoghq.com/organization-settings/api-keys
kubectl create secret generic datadog-secret \
  --from-literal api-key=<YOUR_DATADOG_API_KEY> \
  --namespace datadog
```

For GitOps environments, use Sealed Secrets, SOPS, or the External Secrets
Operator to manage this value. See `secrets/datadog-secrets.yaml` for a
documented template with all three options.

---

## Step 3 — Deploy the Datadog Agent

Apply the `DatadogAgent` CRD. The Operator creates the Node Agent DaemonSet,
Cluster Agent Deployment, and all required RBAC resources automatically.

```bash
kubectl apply -f deploy/kubernetes/datadog/agent/datadog-agent.yaml
```

Verify the rollout (takes 1–2 minutes):
```bash
kubectl get datadogagent -n datadog
kubectl get daemonset datadog -n datadog
kubectl get deployment datadog-cluster-agent -n datadog
```

Or use the Makefile shortcut:
```bash
make deploy-k8s-dd
```

---

## Step 4 — Apply Agent Check ConfigMaps (optional)

These ConfigMaps provide the Datadog Agent with check configurations for
PostgreSQL (DBM) and ActiveMQ. The content is entirely commented out by default —
uncomment each block when you are ready to enable the check.

```bash
kubectl apply -f deploy/kubernetes/datadog/checks/
```

Then mount the ConfigMaps into the Agent by adding a volume/volumeMount override
to `agent/datadog-agent.yaml` (the comments in each ConfigMap file show the exact
override block to add).

---

## Step 5 — Patch gateway-api with Datadog annotations

`services/gateway-api-with-datadog.yaml` is a reference version of the gateway-api
Deployment that adds:

- `tags.datadoghq.com/*` pod labels (Unified Service Tagging)
- `admission.datadoghq.com/enabled: "true"` annotation (auto-injection by Cluster Agent)
- `DD_ENV`, `DD_SERVICE`, `DD_VERSION` env vars (fallback for environments without Admission Controller)
- `DD_AGENT_HOST` via Downward API (hostIP fallback)

Apply it to replace the base Deployment:
```bash
kubectl apply -f deploy/kubernetes/datadog/services/gateway-api-with-datadog.yaml
```

---

## Helm alternative (without the Operator)

If you prefer Helm directly over the Operator:

```bash
# Create the namespace and API key Secret first (see Step 2 above)
kubectl create namespace datadog

helm install datadog datadog/datadog \
  --namespace datadog \
  -f deploy/kubernetes/datadog/agent/helm-values.yaml
```

`agent/helm-values.yaml` mirrors all features in `agent/datadog-agent.yaml` and
includes the same commented-out options for security, profiler, and CSPM.

---

## Unified Service Tagging

All pods must carry these three labels for Datadog to correlate telemetry across
traces, logs, metrics, and profiles:

```yaml
labels:
  tags.datadoghq.com/env:     staging
  tags.datadoghq.com/service: gateway-api
  tags.datadoghq.com/version: "1.0.0"
```

And matching env vars inside the container:
```yaml
env:
  - name: DD_ENV
    valueFrom:
      configMapKeyRef:
        name: finance-app-config
        key: DD_ENV
  - name: DD_SERVICE
    value: gateway-api
  - name: DD_VERSION
    valueFrom:
      configMapKeyRef:
        name: finance-app-config
        key: APP_VERSION
```

Reference: https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/

---

## Admission Controller

When the Cluster Agent's Admission Controller is enabled (it is, by default in
`datadog-agent.yaml`), annotating a pod with:

```yaml
annotations:
  admission.datadoghq.com/enabled: "true"
```

causes the Admission Controller to **automatically inject**:
- `DD_AGENT_HOST`
- `DD_TRACE_AGENT_URL`
- `DD_ENTITY_ID`

into the pod at admission time. The base Deployments in `../base/services/` do
**not** carry this annotation — it is added only in the patched versions under
`services/`.

Reference: https://docs.datadoghq.com/containers/cluster_agent/admission_controller/

---

## Learning Progression

Follow these steps in order to progressively enable observability on the K8s
deployment. The Learning Progression mirrors the one in each service's own README.

| Step | Action | Datadog product |
|---|---|---|
| 1 | Complete Steps 1–3 above (Operator + Agent) | Infrastructure List, Container Map |
| 2 | Apply Unified Service Tags to all Deployments | APM, Logs, Metrics correlation |
| 3 | Uncomment APM init in each service's code; verify traces | APM > Services |
| 4 | Uncomment log annotation on each Deployment; verify `trace_id` | Log Management |
| 5 | Uncomment custom spans in business-critical code paths | APM flame graphs |
| 6 | Uncomment DogStatsD metric calls | Metrics Explorer |
| 7 | Enable Continuous Profiler (`DD_PROFILING_ENABLED=true`) | Continuous Profiler |
| 8 | Apply DBM ConfigMap + PostgreSQL prerequisites | Databases > Query Metrics |
| 9 | Apply ActiveMQ ConfigMap + enable DSM | Data Streams |
| 10 | Enable Data Jobs Monitoring for `batch-processor` | Data Jobs |
| 11 | Add Synthetic API tests for `/health` and `/v1/payments` | Synthetics |

---

## Key References

| Topic | URL |
|---|---|
| Datadog Operator | https://github.com/DataDog/datadog-operator |
| Helm chart | https://github.com/DataDog/helm-charts |
| Admission Controller | https://docs.datadoghq.com/containers/cluster_agent/admission_controller/ |
| Unified Service Tagging | https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/ |
| APM on Kubernetes | https://docs.datadoghq.com/containers/kubernetes/apm/ |
| Log collection | https://docs.datadoghq.com/containers/kubernetes/log/ |
| Database Monitoring | https://docs.datadoghq.com/database_monitoring/ |
| Data Streams Monitoring | https://docs.datadoghq.com/data_streams/ |
| Data Jobs Monitoring | https://docs.datadoghq.com/data_jobs/ |
