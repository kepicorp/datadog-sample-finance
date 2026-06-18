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

1. `make tf-apply-aws` — EKS cluster deployed
2. `make deploy-k8s-eks` — Finance app running
3. `make deploy-k8s-dd` — Datadog Agent running and sending data
4. Secrets populated in AWS Secrets Manager:
   ```bash
   aws secretsmanager put-secret-value \
     --secret-id finance-app/staging/dd-api-key \
     --secret-string "your-dd-api-key" --profile partner
   aws secretsmanager put-secret-value \
     --secret-id finance-app/staging/dd-app-key \
     --secret-string "your-dd-app-key" --profile partner
   ```

## Usage

```bash
# 1. Export keys from Secrets Manager (never put in files)
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

Or use the convenience Makefile targets:
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
