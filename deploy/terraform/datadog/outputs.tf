# =============================================================================
# Finance Sample App — Datadog Terraform Outputs
# =============================================================================

output "log_index_name" {
  description = "Name of the Datadog log index created for the Finance app."
  value       = datadog_logs_index.finance_app.name
}

output "log_index_filter" {
  description = "Log filter query used by the Finance app index."
  value       = datadog_logs_index.finance_app.filter[0].query
}

output "dashboard_url" {
  description = "URL of the Finance app overview dashboard in Datadog."
  value       = "https://app.datadoghq.com/dashboard/${datadog_dashboard.finance_overview.id}"
}

output "monitor_pod_restarts_id" {
  description = "ID of the pod restart monitor."
  value       = datadog_monitor.pod_restarts.id
}

output "monitor_error_rate_id" {
  description = "ID of the error rate monitor."
  value       = datadog_monitor.error_rate.id
}

output "monitor_pods_not_running_id" {
  description = "ID of the pods-not-running monitor."
  value       = datadog_monitor.pods_not_running.id
}

output "span_metrics" {
  description = "Span-based metrics generated from APM traces. Create dashboards and alerts using these metric names."
  value = {
    payment_hits     = datadog_spans_metric.payment_hits.name
    payment_duration = datadog_spans_metric.payment_duration.name
    fraud_hits       = datadog_spans_metric.fraud_hits.name
    batch_records    = datadog_spans_metric.batch_records.name
  }
}

output "log_metrics" {
  description = "Log-based metrics generated from structured logs. Use in monitors and dashboards."
  value = {
    error_count        = datadog_logs_metric.error_count.name
    payments_initiated = datadog_logs_metric.payments_initiated.name
  }
}
