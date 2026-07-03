# GCP GKE — Terraform *(coming soon)*

> **Status:** This module is scaffolded and documented but has not been tested
> end-to-end. The Makefile targets are commented out in the root `Makefile`.
> Contributions welcome.

Provisions the GCP infrastructure for the Finance sample app.
Application workloads are deployed separately using the standard Kubernetes
manifests in `deploy/kubernetes/base/` — Terraform only manages GCP resources.

## What Terraform creates

| Resource | Purpose |
|---|---|
| **GKE Standard cluster** | Regional, 1 node per zone × e2-standard-2 |
| **Node pool** | Least-privilege service account, Workload Identity enabled |
| **Artifact Registry** | One Docker repository per microservice |
| **Secret Manager** | Placeholder secrets for `dd-api-key` and `datadog-dbm-password` |
| **Datadog service account** | Read-only IAM roles for Cloud Monitoring metric collection |

## Workflow

```
┌─────────────────────────────────────────────────────────────────┐
│  Step 1 — Terraform                                             │
│  make tf-apply-gcp           → GKE + Artifact Registry + IAM   │
├─────────────────────────────────────────────────────────────────┤
│  Step 2 — kubectl              (once per developer machine)     │
│  make tf-configure-kubectl-gcp → gcloud container clusters …   │
├─────────────────────────────────────────────────────────────────┤
│  Step 3 — Images                                                │
│  Push service images to Artifact Registry (see below)          │
├─────────────────────────────────────────────────────────────────┤
│  Step 4 — Application                                           │
│  make deploy-k8s             → kubectl apply (base manifests)  │
│  make deploy-k8s-dd          → + Datadog Agent overlay          │
└─────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Terraform | >= 1.5 | `terraform version` |
| `gcloud` CLI | >= 450 | `gcloud version` |
| kubectl | any recent | `kubectl version --client` |
| `make` | any | from the project root |

---

## Authentication — GCP Application Default Credentials

```bash
# Log in once per machine (sets up ADC used by both gcloud and Terraform)
gcloud auth application-default login

# Set your default project
gcloud config set project YOUR_PROJECT_ID

# Verify
gcloud projects describe YOUR_PROJECT_ID
```

For CI/CD, set `GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa-key.json` or use
Workload Identity Federation.

---

## Step 1 — Create `staging.tfvars`

```bash
cp deploy/terraform/gcp/staging.tfvars.example deploy/terraform/gcp/staging.tfvars
# Edit staging.tfvars — set project_id, region, cluster_name, etc.
# staging.tfvars is covered by .gitignore
```

## Step 2 — Plan and apply

```bash
# Review what will be created (no GCP charges at plan time)
make tf-plan-gcp

# Apply — creates GKE cluster, Artifact Registry, IAM (~10-15 min)
make tf-apply-gcp
```

## Step 3 — Configure kubectl

```bash
# Update your local kubeconfig
make tf-configure-kubectl-gcp
# OR run the command directly:
eval "$(cd deploy/terraform/gcp && terraform output -raw get_credentials_command)"

# Verify
kubectl get nodes
```

## Step 4 — Push service images to Artifact Registry

Images built by `make build` must be in Artifact Registry before GKE can pull them.

```bash
cd deploy/terraform/gcp

# Authenticate Docker with Artifact Registry
eval "$(terraform output -raw docker_auth_command)"

# Tag and push all six services
IMAGE_TAG=$(git rev-parse --short HEAD)
for SVC in gateway-api account-service transaction-service \
           fraud-detection notification-service batch-processor; do
  AR_URL=$(terraform output -json artifact_registry_urls | jq -r ".\"${SVC}\"")
  docker tag  finance-sample-app-${SVC}:latest ${AR_URL}:${IMAGE_TAG}
  docker push ${AR_URL}:${IMAGE_TAG}
done
```

Then update the `image:` field in each service manifest under
`deploy/kubernetes/base/services/` to use the Artifact Registry URL:
```yaml
image: europe-west1-docker.pkg.dev/my-project/gateway-api:abc1234
imagePullPolicy: Always   # Always pull from registry on GKE
```

## Step 5 — Deploy the application

```bash
# Deploy the Finance app using the standard Kubernetes manifests
make deploy-k8s

# Check pods
kubectl get pods -n finance

# Deploy with Datadog Agent (requires make deploy-k8s first)
make deploy-k8s-dd
```

---

## Datadog integration (progressive enablement)

Terraform creates the Datadog integration service account and IAM roles
immediately — the expensive/complex parts are commented out and enabled step by step.

### Step A — Connect Datadog to GCP (Cloud Monitoring metrics)

```bash
# Get the SA email
cd deploy/terraform/gcp && terraform output datadog_integration_sa_email
```

Go to **Datadog → Integrations → GCP** and add your project using the service
account email. This enables Cloud Monitoring metrics with no agent required.

For full automation, uncomment `google_service_account_key` and `datadog_integration_gcp`
in `main.tf` (requires the datadog provider — see comments in the file).

### Step B — Enable Pub/Sub log forwarding

1. Uncomment `pubsub.googleapis.com` and `logging.googleapis.com` in the APIs list
2. Uncomment the Pub/Sub and Cloud Logging resources in `main.tf`
3. Set `TF_VAR_datadog_api_key` and re-apply
4. Log entries appear in Datadog Log Management within ~2 minutes

### Step C — Deploy the Datadog Agent to GKE

```bash
make deploy-k8s-dd
```

Follow the 13-step Learning Progression in `deploy/kubernetes/datadog/README.md`
(numbering matches `INSTRUMENTATION.md`).

---

## Secrets — never hardcode

See `../aws/README.md`'s "Secrets — never hardcode" section for the shared rationale
(placeholder-only Terraform secrets, out-of-band population, no `TF_VAR_*` for real
values). Terraform here creates two placeholder secrets in Secret Manager; populate
them out-of-band:

```bash
# Datadog API key
echo -n "your-datadog-api-key" | \
  gcloud secrets versions add dd-api-key --data-file=-

# Datadog DBM PostgreSQL monitoring password
echo -n "your-dbm-password" | \
  gcloud secrets versions add datadog-dbm-password --data-file=-
```

---

## Tear down

```bash
# Remove the application first
make undeploy-k8s

# Then destroy the GCP infrastructure
make tf-destroy-gcp
```

---

## Remote state (recommended for teams)

Uncomment the `backend "gcs"` block in `main.tf`:

```bash
# Create the bucket first
gsutil mb -p YOUR_PROJECT_ID -l europe-west1 gs://your-terraform-state-bucket
gsutil versioning set on gs://your-terraform-state-bucket

# Then uncomment backend "gcs" in main.tf and run:
terraform init -migrate-state
```

---

## Outputs reference

```bash
cd deploy/terraform/gcp

terraform output cluster_name
terraform output get_credentials_command       # run to configure kubectl
terraform output docker_auth_command           # run to auth Docker with AR
terraform output -json artifact_registry_urls  # map of service → AR URL
terraform output datadog_integration_sa_email  # for Datadog GCP integration
terraform output secret_manager_secrets        # Secret Manager secret IDs
```

---

## Key References

| Topic | URL |
|---|---|
| GKE Terraform module | https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_cluster |
| Datadog GCP integration | https://docs.datadoghq.com/integrations/google_cloud_platform/ |
| Datadog Terraform provider | https://registry.terraform.io/providers/DataDog/datadog/latest/docs |
| EKS + Datadog Agent | https://docs.datadoghq.com/containers/kubernetes/ |
| GCP ADC authentication | https://cloud.google.com/docs/authentication/application-default-credentials |
