# =============================================================================
# Finance Sample App — Datadog Terraform Variables
# =============================================================================
# Usage:
#   export TF_VAR_datadog_api_key="$(aws secretsmanager get-secret-value \
#     --secret-id finance-app/staging/dd-api-key --query SecretString --output text)"
#   export TF_VAR_datadog_app_key="$(aws secretsmanager get-secret-value \
#     --secret-id finance-app/staging/dd-app-key --query SecretString --output text)"
#   terraform plan  -var-file="staging.tfvars"
#   terraform apply -var-file="staging.tfvars"
# =============================================================================

variable "datadog_api_key" {
  description = "Datadog API key. Source from AWS Secrets Manager — never hardcode. Use TF_VAR_datadog_api_key env var."
  type        = string
  sensitive   = true
}

variable "datadog_app_key" {
  description = "Datadog Application key. Required by the Datadog provider for write operations. Source from AWS Secrets Manager. Use TF_VAR_datadog_app_key env var."
  type        = string
  sensitive   = true
}

variable "datadog_site" {
  description = "Datadog site (e.g. datadoghq.com, datadoghq.eu). Must match the site used by the Agent."
  type        = string
  default     = "datadoghq.com"
}

variable "environment" {
  description = "Deployment environment. Used to scope tags and index filters."
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "environment must be one of: development, staging, production."
  }
}

variable "cluster_name" {
  description = "EKS cluster name. Used to scope log index filters and dashboard titles."
  type        = string
  default     = "finance-app"
}

variable "log_retention_days" {
  description = "Log retention in days for the finance-app log index."
  type        = number
  default     = 15

  validation {
    condition     = contains([3, 7, 15, 30, 45, 60, 90, 180, 360], var.log_retention_days)
    error_message = "log_retention_days must be a valid Datadog retention value: 3, 7, 15, 30, 45, 60, 90, 180, or 360."
  }
}
