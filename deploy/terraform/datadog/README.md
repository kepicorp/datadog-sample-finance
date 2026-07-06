# Finance App — Datadog Terraform Configuration

Manages all Datadog observability resources for the Finance sample app as code.

## What is provisioned

| Resource | Description |
|---|---|
| `datadog_logs_index.finance_app` | Dedicated log index with 15-day retention, filtered to `kube_cluster_name:finance-app kube_namespace:finance` |
| `datadog_logs_index_order.finance_app` | Places the finance index before `main` so logs are routed correctly |
| `datadog_logs_pipeline.finance_app` | Parsing pipeline: JSON parse → status remap → service remap → trace ID link → finance attribute promotion |
| `datadog_monitor.pod_restarts` | Alerts when any finance pod restarts > 3 times in 15 min |
| `datadog_monitor.error_rate` | Alerts when error log rate > 20/min for any service |
| `datadog_monitor.pods_not_running` | Alerts when running pod count drops below 8 |
| `datadog_dashboard.finance_overview` | Overview dashboard: pod health, CPU/memory, log volume, error rate |

## Prerequisites

This module talks only to the Datadog API — it does **not** require a running cluster.
You can apply it independently of where (or whether) the app is deployed.

**Local:** a Datadog account plus `DD_API_KEY` / `DD_APP_KEY` set in the repo-root `.env`
(see the top-level README). That's all `make dd-secrets` needs to export the `TF_VAR_*` keys.

**AWS EKS:** the keys live in AWS Secrets Manager instead of `.env`. Populate them once
(`make tf-apply-aws` creates the secret containers):
```bash
aws secretsmanager put-secret-value \
  --secret-id finance-app/staging/dd-api-key \
  --secret-string "your-dd-api-key" --profile partner
aws secretsmanager put-secret-value \
  --secret-id finance-app/staging/dd-app-key \
  --secret-string "your-dd-app-key" --profile partner
```

## Usage

The API/App keys must be provided as `TF_VAR_datadog_api_key` / `TF_VAR_datadog_app_key`
environment variables (never in `staging.tfvars`). `make dd-secrets` prints the right
`export` lines for both environments — just `eval` its output.

### Local (Docker Desktop / colima / kind / k3d / minikube)

```bash
# 1. Copy and review variables (first time only). Set datadog_site to match your org.
cp staging.tfvars.example staging.tfvars

# 2. Export the keys. With no valid AWS SSO session, dd-secrets falls back to
#    DD_API_KEY / DD_APP_KEY in your .env at the repo root.
eval "$(make dd-secrets)"

# 3. Plan and apply
make tf-plan-dd
make tf-apply-dd
```

> **Local log-index caveat:** the log index filters on `kube_cluster_name:finance-app`.
> A local cluster usually reports a different cluster name, so local logs may not route into
> the dedicated index. The RUM application, monitors, dashboard, and synthetics still work.
> `make tf-apply-dd` is what creates the RUM app whose credentials `make instrument` injects
> into the frontend — so run it **before** `make instrument`.

### AWS EKS

```bash
# 1. Export keys from Secrets Manager (never put in files). 'make dd-secrets' does this
#    for you when an AWS SSO session is active; the explicit form is:
export TF_VAR_datadog_api_key="$(aws secretsmanager get-secret-value \
  --secret-id finance-app/staging/dd-api-key \
  --query SecretString --output text --profile partner)"

export TF_VAR_datadog_app_key="$(aws secretsmanager get-secret-value \
  --secret-id finance-app/staging/dd-app-key \
  --query SecretString --output text --profile partner)"

# 2. Copy and review variables
cp staging.tfvars.example staging.tfvars

# 3. Plan and apply
make tf-plan-dd
make tf-apply-dd
```

Makefile targets:
```bash
make tf-plan-dd    # terraform plan for Datadog resources
make tf-apply-dd   # terraform apply for Datadog resources
make tf-destroy-dd # destroy all Datadog resources
```

## Key references

| Topic | URL |
|---|---|
| Datadog Terraform provider | https://registry.terraform.io/providers/DataDog/datadog/latest/docs |
| Log indexes | https://docs.datadoghq.com/logs/log_configuration/indexes/ |
| Log pipelines | https://docs.datadoghq.com/logs/log_configuration/pipelines/ |
| Monitors | https://docs.datadoghq.com/monitors/ |
| Dashboards | https://docs.datadoghq.com/dashboards/ |
