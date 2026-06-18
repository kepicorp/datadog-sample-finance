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
