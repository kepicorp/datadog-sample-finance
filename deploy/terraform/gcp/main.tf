# =============================================================================
# Finance Sample App — GCP / GKE Terraform
#
# Provisions the GCP infrastructure only. Application workloads are deployed
# separately using `make deploy-k8s` (kubectl manifests in deploy/kubernetes/base/).
#
# What this creates:
#   - GKE Standard cluster (regional, 3 × e2-standard-2)
#   - Artifact Registry repositories (one per microservice)
#   - GCP Secret Manager entries for DD_API_KEY and DATADOG_DBM_PASSWORD
#   - Datadog integration service account + IAM roles (read-only)
#
# What is commented out (enable progressively alongside Datadog instrumentation):
#   - datadog provider + datadog_integration_gcp resource
#   - Service account key + Secret Manager storage of that key
#   - Pub/Sub log forwarding topic / subscription / Cloud Logging sink
#
# Docs:
#   GKE:         https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_cluster
#   Datadog GCP: https://docs.datadoghq.com/integrations/google_cloud_platform/
# =============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }

    # ── DATADOG PROVIDER ────────────────────────────────────────────────────
    # Uncomment when enabling the Datadog GCP integration (datadog_integration_gcp).
    # Export DD_API_KEY and DD_APP_KEY before running terraform apply.
    # datadog = {
    #   source  = "DataDog/datadog"
    #   version = "~> 3.0"
    # }
  }

  # ── REMOTE STATE (recommended for teams) ─────────────────────────────────
  # backend "gcs" {
  #   bucket = "your-terraform-state-bucket"
  #   prefix = "finance-sample-app/gcp"
  # }
}

# =============================================================================
# PROVIDERS
# =============================================================================

provider "google" {
  project = var.project_id
  region  = var.region

  # Authentication: use Application Default Credentials (ADC).
  # Run once: gcloud auth application-default login
  # No changes needed here — ADC is picked up automatically.
  #
  # For CI/CD, set GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa-key.json
  # or use Workload Identity Federation.
}

# ── DATADOG PROVIDER ──────────────────────────────────────────────────────────
# Uncomment after enabling the datadog provider in required_providers above.
# Authentication via DD_API_KEY and DD_APP_KEY environment variables:
#   export DD_API_KEY=$(gcloud secrets versions access latest --secret=dd-api-key)
#   export DD_APP_KEY=$(gcloud secrets versions access latest --secret=dd-app-key)
#
# provider "datadog" {
#   api_url = "https://api.${var.dd_site}/"
# }
# ─────────────────────────────────────────────────────────────────────────────

# The Kubernetes provider is NOT used here — application workloads are deployed
# via `make deploy-k8s` (kubectl manifests in deploy/kubernetes/base/) after
# Terraform provisions the cluster. This avoids the chicken-and-egg problem
# where the provider would try to authenticate to a cluster that doesn't
# exist yet during the first `terraform plan`.
#
# After `terraform apply`, run:
#   eval "$(terraform output -raw get_credentials_command)"
# Then deploy:
#   make deploy-k8s

# =============================================================================
# ENABLE REQUIRED GCP APIS
# =============================================================================

resource "google_project_service" "apis" {
  for_each = toset([
    "container.googleapis.com",        # GKE
    "artifactregistry.googleapis.com", # Artifact Registry
    "secretmanager.googleapis.com",    # Secret Manager
    "iam.googleapis.com",              # IAM (Datadog service account)
    "cloudresourcemanager.googleapis.com",
    # Uncomment when enabling Pub/Sub log forwarding (Step 5 below):
    # "pubsub.googleapis.com",
    # "logging.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# =============================================================================
# NETWORKING — VPC (use default for simplicity; create custom VPC for production)
# =============================================================================
# This configuration uses the default VPC. For production, create a dedicated VPC:
#
# resource "google_compute_network" "finance" { ... }
# resource "google_compute_subnetwork" "finance" { ... }

# =============================================================================
# GKE STANDARD CLUSTER
# =============================================================================

resource "google_container_cluster" "finance" {
  name     = var.cluster_name
  location = var.region

  # We manage the node pool separately for better lifecycle control.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Workload Identity lets pods authenticate to GCP APIs without key files.
  # Required for pulling from Artifact Registry from the Finance app pods.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Use VPC-native networking (alias IP ranges) — required for GKE Dataplane V2
  # and better Pod/Service isolation.
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {}

  # Disable basic auth and client certificate issuance.
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  # Enable Cloud Logging and Cloud Monitoring for the cluster control plane.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus { enabled = true }
  }

  depends_on = [google_project_service.apis["container.googleapis.com"]]
}

# =============================================================================
# NODE POOL
# =============================================================================

resource "google_container_node_pool" "finance_nodes" {
  name     = "${var.cluster_name}-nodes"
  cluster  = google_container_cluster.finance.name
  location = var.region

  node_count = var.nodes_per_zone # per zone; total = nodes_per_zone × 3 zones

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = 50
    disk_type    = "pd-standard"

    # Least-privilege service account for nodes — only Artifact Registry reader.
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    # Enable Workload Identity on nodes.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      env        = var.environment
      managed-by = "terraform"
    }

    # Datadog Unified Service Tagging — add to every node for container-level correlation.
    metadata = {
      disable-legacy-endpoints = "true"
    }

    shielded_instance_config {
      enable_secure_boot = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }
}

# =============================================================================
# GKE NODE SERVICE ACCOUNT (least privilege)
# =============================================================================

resource "google_service_account" "gke_nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "Finance GKE Node Service Account"
}

# Grant Artifact Registry read access so nodes can pull service images.
resource "google_project_iam_member" "gke_nodes_artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# =============================================================================
# ARTIFACT REGISTRY — one repository per microservice
# =============================================================================

locals {
  services = toset([
    "gateway-api",
    "account-service",
    "transaction-service",
    "fraud-detection",
    "notification-service",
    "batch-processor",
  ])
}

resource "google_artifact_registry_repository" "services" {
  for_each = local.services

  location      = var.region
  repository_id = each.value
  description   = "Finance sample app — ${each.value} Docker images"
  format        = "DOCKER"

  labels = {
    env        = var.environment
    service    = each.value
    managed-by = "terraform"
  }

  depends_on = [google_project_service.apis["artifactregistry.googleapis.com"]]
}

# =============================================================================
# SECRET MANAGER — placeholder secrets for Datadog credentials
# =============================================================================
# These secrets are created as empty shells. Populate values out-of-band:
#   echo -n "your-api-key" | gcloud secrets versions add dd-api-key --data-file=-

resource "google_secret_manager_secret" "dd_api_key" {
  secret_id = "dd-api-key"

  replication {
    auto {}
  }

  labels = {
    env        = var.environment
    managed-by = "terraform"
    purpose    = "datadog-agent"
  }

  depends_on = [google_project_service.apis["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret" "datadog_dbm_password" {
  secret_id = "datadog-dbm-password"

  replication {
    auto {}
  }

  labels = {
    env        = var.environment
    managed-by = "terraform"
    purpose    = "datadog-dbm"
  }

  depends_on = [google_project_service.apis["secretmanager.googleapis.com"]]
}

# =============================================================================
# DATADOG INTEGRATION — IAM service account (always created for later use)
# =============================================================================
# The service account and IAM bindings are always provisioned so the Datadog
# GCP integration can be enabled quickly without a re-apply.
# The SA key and the Datadog registration resource are commented out —
# uncomment them when you are ready to enable the integration.

resource "google_service_account" "datadog_integration" {
  account_id   = "datadog-integration"
  display_name = "Datadog GCP Integration Service Account"
  description  = "Read-only access for Datadog to collect Cloud Monitoring metrics and resource metadata."
}

locals {
  datadog_integration_roles = [
    "roles/compute.viewer",
    "roles/monitoring.viewer",
    "roles/cloudasset.viewer",
    "roles/browser",
    "roles/container.viewer", # GKE cluster metadata
    "roles/pubsub.viewer",    # Pub/Sub queue depth metrics
    "roles/logging.viewer",   # Cloud Logging access
  ]
}

resource "google_project_iam_member" "datadog_integration_roles" {
  for_each = toset(local.datadog_integration_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.datadog_integration.email}"
}

# ── DATADOG INTEGRATION — Step 1: create and store the SA key ────────────────
# Uncomment after enabling the datadog provider above.
# The JSON key is base64-decoded and stored in Secret Manager.
# SECURITY: The key appears in Terraform state — use Workload Identity Federation
# for production to avoid storing long-lived keys.
#
# resource "google_service_account_key" "datadog_integration" {
#   service_account_id = google_service_account.datadog_integration.name
# }
#
# resource "google_secret_manager_secret" "datadog_sa_key" {
#   secret_id = "datadog-integration-sa-key"
#   replication { auto {} }
#   labels = { env = var.environment, managed-by = "terraform" }
# }
#
# resource "google_secret_manager_secret_version" "datadog_sa_key" {
#   secret      = google_secret_manager_secret.datadog_sa_key.id
#   secret_data = base64decode(google_service_account_key.datadog_integration.private_key)
# }
#
# ── DATADOG INTEGRATION — Step 2: register the integration in Datadog ────────
# Requires: datadog provider uncommented, DD_API_KEY + DD_APP_KEY exported.
# Docs: https://docs.datadoghq.com/integrations/google_cloud_platform/
#
# resource "datadog_integration_gcp" "finance" {
#   project_id     = var.project_id
#   private_key_id = jsondecode(base64decode(google_service_account_key.datadog_integration.private_key)).private_key_id
#   private_key    = jsondecode(base64decode(google_service_account_key.datadog_integration.private_key)).private_key
#   client_email   = google_service_account.datadog_integration.email
#   client_id      = google_service_account.datadog_integration.unique_id
#   host_filters   = "env:${var.environment}"
#   automute       = true
# }
# ─────────────────────────────────────────────────────────────────────────────

# ── DATADOG INTEGRATION — Step 3: Pub/Sub log forwarding ─────────────────────
# Forwards GKE workload logs to Datadog Log Management via Cloud Logging sink.
# Docs: https://docs.datadoghq.com/integrations/google_cloud_platform/#log-collection
#
# Uncomment the "pubsub.googleapis.com" and "logging.googleapis.com" API entries
# above, then uncomment these resources and re-apply.
#
# resource "google_pubsub_topic" "datadog_logs" {
#   name                       = "datadog-log-forwarding"
#   labels                     = { env = var.environment, managed-by = "terraform" }
#   message_retention_duration = "86400s"
#   depends_on = [google_project_service.apis["pubsub.googleapis.com"]]
# }
#
# resource "google_pubsub_topic" "datadog_logs_dlq" {
#   name       = "datadog-log-forwarding-dlq"
#   labels     = { env = var.environment, managed-by = "terraform" }
#   depends_on = [google_project_service.apis["pubsub.googleapis.com"]]
# }
#
# resource "google_pubsub_subscription" "datadog_logs_push" {
#   name  = "datadog-log-forwarding-push"
#   topic = google_pubsub_topic.datadog_logs.name
#
#   push_config {
#     # For production, switch to OIDC auth and remove the API key from the URL.
#     push_endpoint = "https://gcp-intake.logs.${var.dd_site}/api/v2/logs?dd-api-key=${var.datadog_api_key}&dd-protocol=gcp"
#   }
#
#   ack_deadline_seconds       = 20
#   message_retention_duration = "86400s"
#   dead_letter_policy {
#     dead_letter_topic     = google_pubsub_topic.datadog_logs_dlq.id
#     max_delivery_attempts = 5
#   }
#   retry_policy {
#     minimum_backoff = "10s"
#     maximum_backoff = "600s"
#   }
# }
#
# resource "google_logging_project_sink" "datadog_logs" {
#   name                   = "datadog-log-sink"
#   destination            = "pubsub.googleapis.com/${google_pubsub_topic.datadog_logs.id}"
#   unique_writer_identity = true
#   filter = <<-EOT
#     resource.type=("k8s_container" OR "k8s_node" OR "k8s_cluster")
#     OR (log_id("cloudaudit.googleapis.com/activity") severity >= WARNING)
#   EOT
#   depends_on = [google_pubsub_topic.datadog_logs]
# }
#
# resource "google_pubsub_topic_iam_member" "datadog_sink_publisher" {
#   topic  = google_pubsub_topic.datadog_logs.name
#   role   = "roles/pubsub.publisher"
#   member = google_logging_project_sink.datadog_logs.writer_identity
# }
# ─────────────────────────────────────────────────────────────────────────────
