# =============================================================================
# Finance Sample App — GCP Terraform Variables
# =============================================================================
# Non-sensitive values: put in staging.tfvars (safe to commit)
# Sensitive values:     inject via TF_VAR_* environment variables
#
# Example:
#   cp staging.tfvars.example staging.tfvars
#   terraform plan  -var-file="staging.tfvars"
#   terraform apply -var-file="staging.tfvars"
# =============================================================================

variable "project_id" {
  type        = string
  description = "GCP project ID where all resources will be created."

  validation {
    condition     = length(var.project_id) > 0
    error_message = "project_id must not be empty."
  }
}

variable "region" {
  type        = string
  description = "GCP region for the GKE cluster and Artifact Registry (e.g. europe-west1, us-central1)."
  default     = "europe-west1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a valid GCP region name, e.g. europe-west1."
  }
}

variable "cluster_name" {
  type        = string
  description = "Name of the GKE cluster."
  default     = "finance-gke"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,38}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 2–40 lowercase alphanumeric characters or hyphens."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment. Used as a resource label and as DD_ENV for Datadog Unified Service Tagging."
  default     = "staging"

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "environment must be one of: dev, staging, production."
  }
}

variable "node_machine_type" {
  type        = string
  description = "GCE machine type for GKE worker nodes. e2-standard-2 (2 vCPU / 8 GB) is the minimum for the Finance app stack."
  default     = "e2-standard-2"
}

variable "nodes_per_zone" {
  type        = number
  description = "Number of nodes per zone. Total node count = nodes_per_zone × number of zones in the region."
  default     = 1
}

# =============================================================================
# DATADOG INTEGRATION (optional — only needed when enabling DD resources)
# =============================================================================

variable "dd_site" {
  type        = string
  description = "Datadog site URL. Determines which regional intake endpoint receives telemetry. See https://docs.datadoghq.com/getting_started/site/"
  default     = "datadoghq.com"

  validation {
    condition = contains([
      "datadoghq.com",
      "datadoghq.eu",
      "us3.datadoghq.com",
      "us5.datadoghq.com",
      "ap1.datadoghq.com",
      "ddog-gov.com",
    ], var.dd_site)
    error_message = "dd_site must be a valid Datadog site. See https://docs.datadoghq.com/getting_started/site/"
  }
}

variable "datadog_api_key" {
  type        = string
  description = <<-EOT
    Datadog API key. Only required when enabling the Pub/Sub log forwarding resource
    (the API key is embedded in the push subscription URL).
    Leave empty while using the base cluster-only configuration.

    SECURITY: Never hardcode. Inject via environment variable:
      export TF_VAR_datadog_api_key=$(gcloud secrets versions access latest --secret=dd-api-key)
  EOT
  sensitive   = true
  default     = ""

  validation {
    # Empty (not yet needed) OR exactly 32 characters (valid Datadog API key).
    condition     = length(var.datadog_api_key) == 0 || length(var.datadog_api_key) == 32
    error_message = "datadog_api_key must be empty or exactly 32 characters (a valid Datadog API key)."
  }
}
