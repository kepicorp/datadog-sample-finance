# =============================================================================
# Finance Sample App — GCP Terraform Outputs
# =============================================================================
# Retrieve after apply:
#   terraform output                         # all outputs
#   terraform output -raw get_credentials_command | bash
#   terraform output -json artifact_registry_urls

# =============================================================================
# GKE CLUSTER
# =============================================================================

output "cluster_name" {
  description = "Name of the provisioned GKE cluster."
  value       = google_container_cluster.finance.name
}

output "cluster_location" {
  description = "GCP region where the GKE cluster is deployed."
  value       = google_container_cluster.finance.location
}

output "cluster_endpoint" {
  description = "IP address of the GKE control plane. Marked sensitive — use get_credentials_command to configure kubectl instead."
  value       = google_container_cluster.finance.endpoint
  sensitive   = true
}

output "get_credentials_command" {
  description = "Run this command to configure kubectl after the cluster is provisioned."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.finance.name} --region ${google_container_cluster.finance.location} --project ${var.project_id}"
}

output "deploy_command" {
  description = "Run this after configuring kubectl to deploy the Finance app to GKE."
  value       = "make deploy-k8s"
}

# =============================================================================
# ARTIFACT REGISTRY
# =============================================================================

output "artifact_registry_hostname" {
  description = "Artifact Registry Docker hostname for this region. Configure Docker auth with: gcloud auth configure-docker <hostname>"
  value       = "${var.region}-docker.pkg.dev"
}

output "artifact_registry_urls" {
  description = "Map of microservice name → full Artifact Registry Docker repository URL."
  value = {
    for svc, repo in google_artifact_registry_repository.services :
    svc => "${var.region}-docker.pkg.dev/${var.project_id}/${repo.repository_id}"
  }
}

output "docker_auth_command" {
  description = "Run this to authenticate Docker with Artifact Registry before pushing images."
  value       = "gcloud auth configure-docker ${var.region}-docker.pkg.dev"
}

# =============================================================================
# SECRET MANAGER
# =============================================================================

output "secret_manager_secrets" {
  description = "Map of purpose → Secret Manager secret ID. Populate values with: gcloud secrets versions add <secret-id> --data-file=-"
  value = {
    dd_api_key           = google_secret_manager_secret.dd_api_key.secret_id
    datadog_dbm_password = google_secret_manager_secret.datadog_dbm_password.secret_id
  }
}

# =============================================================================
# DATADOG INTEGRATION SERVICE ACCOUNT
# =============================================================================

output "datadog_integration_sa_email" {
  description = "Email of the Datadog integration service account. Used when registering the GCP integration in Datadog (Integrations > GCP)."
  value       = google_service_account.datadog_integration.email
}

output "datadog_integration_sa_unique_id" {
  description = "Unique numeric ID of the Datadog integration service account. Used as client_id in the datadog_integration_gcp resource."
  value       = google_service_account.datadog_integration.unique_id
}

# =============================================================================
# GKE NODE SERVICE ACCOUNT
# =============================================================================

output "gke_node_sa_email" {
  description = "Email of the least-privilege GKE node service account (roles/artifactregistry.reader only)."
  value       = google_service_account.gke_nodes.email
}
