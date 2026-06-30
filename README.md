# Finance Sample App — Datadog Observability

A hands-on instrumentation learning tool for Datadog observability. The application simulates a simplified financial platform. All Datadog-specific code ships **commented out** so engineers can progressively uncomment, configure, and validate each observability layer.

---

## Prerequisites

The app runs on Kubernetes. You need either a **local K8s cluster** or an **AWS account** for EKS.

### Option A — Local Kubernetes (recommended for getting started)

Any of the following work out of the box:

| Tool | Install | Notes |
|---|---|---|
| **Colima** (macOS) | `brew install colima && colima start --kubernetes` | Lightweight, runs k3s inside Lima VM. Recommended on Apple Silicon. |
| **k3d** (macOS/Linux) | `brew install k3d && k3d cluster create finance` | Runs k3s in Docker containers. Fast startup. |
| **minikube** | `brew install minikube && minikube start` | Good Docker Desktop alternative. |
| **Docker Desktop** | Enable Kubernetes in Docker Desktop settings | Simplest if already using Docker Desktop. |
| **kind** | `brew install kind && kind create cluster` | Kubernetes-in-Docker, popular for CI. |

**Colima example (Apple Silicon):**
```bash
brew install colima kubectl helm
colima start --kubernetes --cpu 4 --memory 8 --arch aarch64
kubectl get nodes   # should show 1 node Ready
```

> **Loading images into local k3s (Colima):** local Docker images are not
> automatically available inside the cluster. Load them after `make build`:
> ```bash
> for svc in gateway-api account-service transaction-service \
>            fraud-detection notification-service batch-processor; do
>   docker save finance-sample-app-$svc:latest \
>     | colima ssh -- sudo ctr image import -
> done
> ```
> For k3d use `k3d image import`, for minikube use `minikube image load`,
> for kind use `kind load docker-image`.

### Option B — AWS EKS

Requires:
- AWS CLI ≥ 2.x with an SSO profile configured (`aws configure sso`)
- Terraform ≥ 1.5
- An AWS account with permissions to create EKS, VPC, ECR, IAM, and Secrets Manager resources

See the [AWS EKS section](#aws--eks-via-terraform) for the full provisioning workflow.

### Common tools (both options)

```bash
# macOS
brew install kubectl helm

# Verify
kubectl version --client
helm version
```

You also need a **Datadog account** with an API key and an App key:
- API key: https://app.datadoghq.com/organization-settings/api-keys
- App key: https://app.datadoghq.com/organization-settings/application-keys

---

## Architecture

```
                        ┌─────────────────────────────────────────────────────┐
                        │                  NGINX (reverse proxy)               │
                        └────────────────────────┬────────────────────────────┘
                                                 │
                        ┌────────────────────────▼────────────────────────────┐
                        │           gateway-api  (Python / FastAPI)            │
                        │         REST API · auth middleware · :8080           │
                        └──────────────────┬──────────────────┬───────────────┘
                                           │                  │
               ┌───────────────────────────▼──┐    ┌──────────▼──────────────────┐
               │  account-service              │    │  transaction-service         │
               │  (Java / Spring Boot)         │    │  (Node.js / Express)         │
               │  Account CRUD · balance · :8081│   │  Payment · ledger · :8082    │
               └───────────────┬───────────────┘    └──────────┬──────────────────┘
                               │    JMS produce                │    JMS produce
                               │    fraud.score.queue          │    alert.queue
                               │                               │
                        ┌──────▼───────────────────────────────▼──────────────┐
                        │           Apache ActiveMQ Artemis (JMS broker)       │
                        └────────────────┬─────────────────────┬──────────────┘
                                         │ JMS consume          │ JMS consume
                     ┌───────────────────▼───┐       ┌──────────▼──────────────┐
                     │  fraud-detection       │       │  notification-service    │
                     │  (Python)              │       │  (Go)                    │
                     │  Async fraud scoring   │       │  Email / SMS stubs       │
                     │  fraud.score.queue     │       │  alert.queue             │
                     └───────────────────────┘       └─────────────────────────┘

                        ┌─────────────────────────────────────────────────────┐
                        │           batch-processor  (Java / Spring Batch)     │
                        │   Nightly reconciliation · end-of-day settlement     │
                        │   Runs on schedule — not in the request path         │
                        └──────────────────────────┬──────────────────────────┘
                                                   │
                        ┌──────────────────────────▼──────────────────────────┐
                        │           PostgreSQL  (primary ledger DB · :5432)    │
                        └─────────────────────────────────────────────────────┘

                        ┌─────────────────────────────────────────────────────┐
                        │           Redis  (session cache · :6379)             │
                        └─────────────────────────────────────────────────────┘
```

---

## Services

| Service | Language | Port | Role |
|---|---|---|---|
| `gateway-api` | Python (FastAPI) | 8080 | Public REST API, authentication middleware, request routing |
| `account-service` | Java (Spring Boot) | 8081 | Account CRUD, balance enquiry, JMS producer to `fraud.score.queue` |
| `transaction-service` | Node.js (Express) | 8082 | Payment initiation, ledger write, JMS producer to `alert.queue` |
| `fraud-detection` | Python | — | Async fraud scoring, JMS consumer on `fraud.score.queue` |
| `notification-service` | Go | — | Async email/SMS stubs, JMS consumer on `alert.queue` |
| `batch-processor` | Java (Spring Batch) | — | Nightly reconciliation job and end-of-day settlement |

Supporting infrastructure:

| Component | Image | Port | Purpose |
|---|---|---|---|
| PostgreSQL | `postgres:15` | 5432 | Primary ledger database |
| Redis | `redis:7` | 6379 | Session store and application cache |
| ActiveMQ Artemis | `apache/activemq-artemis` | 61616 / 8161 | JMS 2.0 broker for async messaging |
| NGINX | `nginx:1.25` | 80 | Reverse proxy in front of gateway-api |
| **Keycloak** | `quay.io/keycloak/keycloak:26.0` | **8089** | **Open-source IdP — SAML 2.0 SSO for Datadog + OIDC for gateway-api** |

> **Why Keycloak?** Keycloak is the most widely deployed open-source SAML 2.0 / OIDC identity provider in banking and insurance environments. It mirrors enterprise IdPs (Okta, Azure AD, PingFederate) while staying fully open-source, making it ideal for Datadog SSO demos and partner workshops. See `identity-provider/README.md` for the full Datadog SAML SSO setup guide.

> **Why ActiveMQ Artemis?** It is a JMS 2.0-compliant broker natively supported by Spring Boot (`spring-boot-starter-artemis`) and auto-instrumented by `dd-trace-java`. It mirrors messaging patterns common in banking and insurance (IBM MQ, TIBCO EMS) while being open-source and easy to run locally.

---

## Quick Start (Docker — no Datadog config required)

The application runs cleanly with all instrumentation commented out. No `DD_API_KEY` is needed for the first run.

```bash
# 1. Clone and enter the repository
git clone <repo-url> && cd impl

# 2. Build all service images
make build

# 3. Start the full stack
make up
```

Verify the stack is healthy:

```bash
make health
# Expected: {"status": "ok", "services": {...}}
```

Useful commands:

```bash
make logs     # Tail all service logs
make down     # Tear down the stack
make version  # Print the current DD_VERSION (git short SHA)
```

Gateway API is available at `http://localhost:8080`. ActiveMQ management console is at `http://localhost:8161` (admin / admin).

---

## Generating Traffic

Once the stack is up, use the included traffic generator to drive realistic load against all services:

```bash
# Smoke-test: one pass through every scenario type
python3 scripts/generate-traffic.py --once

# Continuous traffic at 1 req/s — Ctrl-C to stop
python3 scripts/generate-traffic.py

# Higher rate for populating APM dashboards
python3 scripts/generate-traffic.py --rate 3 --duration 300
```

The script (pure Python stdlib — no install needed) automatically:
- Obtains JWT Bearer tokens from Keycloak for all four finance-realm users
- Seeds test accounts on `account-service`
- Runs a weighted mix of balance checks, payments, account lookups, health probes, and intentional error scenarios (401, 404, 422)
- Refreshes tokens before they expire

| Scenario | Weight | Path |
|---|---|---|
| Balance check (JWT) | 30 % | gateway-api → account-service |
| Payment initiation (JWT) | 25 % | gateway-api → transaction-service → ActiveMQ |
| Account lookup (direct) | 20 % | account-service → PostgreSQL |
| Health checks | 10 % | gateway-api, account-service, transaction-service |
| 404 / 401 / 422 error cases | 15 % | Various |

Full documentation: `scripts/README.md`

---

## Learning Progression

Each service directory contains its own `README.md` with a **12-step Learning Progression** for progressively enabling Datadog observability. The steps are the same across all services:

| Step | What you enable |
|---|---|
| 1 | Datadog Agent sidecar / DaemonSet |
| 2 | Unified Service Tags (`DD_ENV`, `DD_SERVICE`, `DD_VERSION`) |
| 3 | APM auto-instrumentation — verify traces in APM > Services |
| 4 | Log correlation — verify `trace_id` in Log Management |
| 5 | Custom spans for critical business operations |
| 6 | DogStatsD custom metrics (counters, histograms, gauges) |
| 7 | Continuous Profiler — validate CPU flame graphs |
| 8 | RUM Browser SDK (frontend stub) |
| 9 | Database Monitoring (DBM) for PostgreSQL |
| 10 | Data Streams Monitoring (DSM) for the JMS / ActiveMQ pipeline |
| 11 | Data Jobs Monitoring for the Spring Batch reconciliation job |
| 12 | Synthetic API tests for `/health` and `/v1/payments` |

**For step-by-step instrumentation instructions covering all services**, see
[**INSTRUMENTATION.md**](./INSTRUMENTATION.md). It covers Steps 1–9 above with
exact file locations, code snippets for each language (Python, Java, Node.js,
Go), and validation steps for each signal.

Start with `gateway-api/README.md` and work outward to the downstream services.

---

## Deployment Targets

Deployment artefacts live under `deploy/`. All three targets share the same application manifests in `deploy/kubernetes/base/` — only the infrastructure provisioning differs.

```
deploy/
  docker/                  Docker Compose — fastest local start, two files
  kubernetes/
    base/                  K8s manifests — used by all three targets
    datadog/               Datadog Agent overlay (Operator CRD + checks)
  terraform/
    aws/                   AWS EKS + ECR + VPC + IAM + Secrets Manager
    gcp/                   GCP GKE — scaffolded, not yet available
```

---

### Docker Compose — local development

Two files are provided — start without Datadog first to verify the app works:

| Command | File | Purpose |
|---|---|---|
| `make up` | `docker-compose.base.yml` | No Datadog — fastest start |
| `make up-dd` | `docker-compose.datadog.yml` | Adds the Datadog Agent + DD_ env vars |

```bash
# 1. Configure credentials
cp deploy/docker/.env.example deploy/docker/.env
# edit .env: set POSTGRES_PASSWORD, ARTEMIS_PASSWORD
# (DD_API_KEY only needed for make up-dd)

# 2. Build and start
make build
make up

# 3. Open the dashboard
open http://localhost:3000   # nginx frontend + Keycloak login

# 4. Run tests
make test                    # 37 assertions, all green
```

See `deploy/docker/README.md` for Keycloak users, all make commands, and the 12-step Learning Progression.

---

### Kubernetes — any cluster

Once `kubectl` is pointed at a cluster (local or EKS), the deployment is identical:

```bash
make deploy-k8s      # deploys deploy/kubernetes/base/ — no Datadog
make deploy-k8s-dd   # adds deploy/kubernetes/datadog/ overlay (Agent, checks)
make undeploy-k8s    # removes the finance namespace
```

See `deploy/kubernetes/base/README.md` for image-loading instructions for local clusters (kind, minikube, Docker Desktop).

See `deploy/kubernetes/datadog/README.md` for the Datadog Operator + Agent setup.

---

### AWS — EKS via Terraform

Terraform creates the AWS infrastructure; `make deploy-k8s` deploys the app.

#### Prerequisites
- AWS CLI >= 2.x
- Terraform >= 1.5
- An AWS SSO profile configured: `aws configure sso`

#### Full workflow

```bash
# 1. Authenticate
aws sso login --profile <your-profile>

# 2. Configure Terraform variables
cp deploy/terraform/aws/staging.tfvars.example deploy/terraform/aws/staging.tfvars
# edit staging.tfvars: set aws_profile, aws_region, cluster_name

# 3. Plan and review
make tf-plan-aws

# 4. Provision AWS infrastructure (~15-20 min)
#    Creates: EKS cluster, VPC, ECR repositories, IAM roles, Secrets Manager entries
make tf-apply-aws

# 5. Configure kubectl
make tf-configure-kubectl
# kubectl get nodes  — verify cluster is reachable

# 6. Build and push service images to ECR
#    Ensure AWS_PROFILE is still exported from step 1.
eval "$(cd deploy/terraform/aws && terraform output -raw ecr_login_command)"

# On Apple Silicon (ARM) Macs — use build-ecr which cross-compiles for linux/amd64.
# EKS nodes run x86_64; pushing ARM images causes 'exec format error' on startup.
make build-ecr

# On x86_64 hosts — build locally then tag and push:
# make build
# IMAGE_TAG=$(git rev-parse --short HEAD)
# for SVC in gateway-api account-service transaction-service \
#            fraud-detection notification-service batch-processor; do
#   ECR_URL=$(cd deploy/terraform/aws && terraform output -json ecr_registry_urls | jq -r ".\"${SVC}\"")
#   docker tag  finance-sample-app-${SVC}:latest ${ECR_URL}:${IMAGE_TAG}
#   docker push ${ECR_URL}:${IMAGE_TAG}
# done

# 7. Deploy the application (use deploy-k8s-eks when kubectl points at EKS)
make deploy-k8s-eks

# 8. Optionally add the Datadog Agent
#    Set DD_API_KEY in AWS Secrets Manager first (if not already set):
#    aws secretsmanager put-secret-value --secret-id finance-app/staging/dd-api-key \
#      --secret-string "your-key" --profile <your-profile> --region <region>
#    deploy-k8s-dd auto-detects EKS and fetches the key from Secrets Manager:
make deploy-k8s-dd

# 9. Apply Datadog observability resources (log index, pipeline, monitors, dashboard)
#    dd-secrets reads aws_region + aws_profile from staging.tfvars automatically:
eval "$(make dd-secrets)"
make tf-apply-dd

# 10. Enable instrumentation, rebuild images, and roll out
make instrument
make build-ecr
make deploy-k8s-eks

# 11. Tear down when done
#     tf-destroy-aws handles K8s cleanup (ELB release) automatically before
#     deleting the EKS cluster and VPC. No need to run undeploy-k8s first.
make tf-destroy-aws
```

#### Datadog Terraform credentials

`make tf-apply-dd` and `make tf-plan-dd` require two Terraform variables that
must **never** be committed to source control:

| Variable | Secret Manager path |
|---|---|
| `TF_VAR_datadog_api_key` | `finance-app/staging/dd-api-key` |
| `TF_VAR_datadog_app_key` | `finance-app/staging/dd-app-key` |

Use `dd-secrets` to export them in one step — it reads `aws_region` and
`aws_profile` from `deploy/terraform/aws/staging.tfvars` automatically:

```bash
eval "$(make dd-secrets)"   # exports both TF_VAR_* into your current shell
make tf-apply-dd
```

If the secrets haven't been populated yet, set them once:

```bash
aws secretsmanager put-secret-value \
  --secret-id finance-app/staging/dd-api-key \
  --secret-string "<your-dd-api-key>" \
  --profile <your-profile> --region <region>

aws secretsmanager put-secret-value \
  --secret-id finance-app/staging/dd-app-key \
  --secret-string "<your-dd-app-key>" \
  --profile <your-profile> --region <region>
```

---

#### Teardown

```bash
make tf-destroy-aws
```

`tf-destroy-aws` handles all dependency ordering that plain `terraform destroy`
gets wrong:

| Step | What it does | Why |
|---|---|---|
| 0 | Deletes the `finance` K8s namespace | Releases the AWS ELB provisioned by the `LoadBalancer` service — without this, VPC deletion fails with `DependencyViolation` |
| 1 | Deletes EKS node groups via AWS CLI | Avoids `ResourceInUseException: Cluster has nodegroups attached` |
| 2 | Deletes EKS add-ons via AWS CLI | Required before the cluster itself can be deleted |
| 3 | Deletes the EKS cluster | |
| 4 | Force-deletes Secrets Manager secrets | Avoids `secret is scheduled for deletion` on re-apply |
| 5 | Deletes ECR repositories | |
| 7 | Runs `terraform destroy` | Cleans up VPC, subnets, IAM roles, KMS keys, CloudWatch log groups |

There is no separate `tf-force-destroy-aws` target — `tf-destroy-aws` already handles all failure modes.

See `deploy/terraform/aws/README.md` for full details on SSO profiles, outputs reference, remote state, and Datadog integration steps.

Reference: https://docs.datadoghq.com/integrations/amazon_web_services/

---

### GCP — GKE via Terraform *(coming soon)*

> The GCP Terraform module is scaffolded in `deploy/terraform/gcp/` but has not
> been tested end-to-end yet. The Makefile targets (`tf-plan-gcp`, `tf-apply-gcp`,
> etc.) are commented out until GCP support is complete.
>
> See `deploy/terraform/gcp/README.md` and
> https://docs.datadoghq.com/integrations/google_cloud_platform/ for reference.

---

## Security Notes

**`DD_API_KEY` is never committed to this repository.** Set it as an environment variable or inject it from a secrets manager at runtime:

- Docker: export `DD_API_KEY` in your shell before running `make up`, or copy `.env.example` to `.env` and fill in the value (`.env` is git-ignored)
- Kubernetes: store in a K8s Secret and reference via `valueFrom.secretKeyRef`
- AWS: store in AWS Secrets Manager; the Terraform module creates the entry
- GCP: store in GCP Secret Manager *(coming soon — see `deploy/terraform/gcp/`)*

**PII masking:** Financial data (card numbers, IBANs, SSNs, account balances) must never appear in trace tags, log messages, or DBM query samples. The Agent `obfuscation_config` and `replace_tags` examples are documented in each service's `env.example`.

**DBM monitoring user:** The PostgreSQL monitoring user must be read-only (`pg_monitor` role only — never `pg_superuser`). Set it up before enabling DBM: `deploy/kubernetes/datadog/checks/postgres-check.yaml` contains the setup SQL in its header comments.

**RUM Session Replay:** The frontend stub enables privacy mode by default (`defaultPrivacyLevel: 'mask-user-input'`). Do not disable this for any environment that processes real financial data.

**Keycloak passwords:** The sample user passwords in `identity-provider/realm-export/finance-realm.json` are for local development only. Rotate them via the Keycloak admin console before any staging or production deployment. Store the admin password in your secrets manager — never hardcode it in `.env` files committed to source control.

---

## Identity Provider

Keycloak (`identity-provider/`) provides:

- **Datadog SAML SSO** — configure organisation-level SSO so your team logs into Datadog via Keycloak (or any upstream corporate IdP federated through Keycloak)
- **OIDC for gateway-api** — validate JWT Bearer tokens per request and inject authenticated user identity into APM traces and logs
- **Finance roles** — `finance-analyst`, `finance-trader`, `finance-admin`, `finance-auditor` mapped to Datadog roles

Admin console: http://localhost:8089 (running after `make up`)

Full guide: `identity-provider/README.md`

---

## Key Datadog Documentation

| Topic | URL |
|---|---|
| Unified Service Tagging | https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/ |
| APM setup (all languages) | https://docs.datadoghq.com/tracing/trace_collection/ |
| Log correlation | https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/ |
| DogStatsD custom metrics | https://docs.datadoghq.com/developers/dogstatsd/ |
| Continuous Profiler | https://docs.datadoghq.com/profiler/ |
| Database Monitoring | https://docs.datadoghq.com/database_monitoring/ |
| DBM — PostgreSQL self-hosted | https://docs.datadoghq.com/database_monitoring/setup_postgres/selfhosted/ |
| DBM + APM correlation | https://docs.datadoghq.com/database_monitoring/connect_dbm_and_apm/ |
| Data Streams Monitoring | https://docs.datadoghq.com/data_streams/ |
| Data Jobs Monitoring | https://docs.datadoghq.com/data_jobs/ |
| ActiveMQ integration | https://docs.datadoghq.com/integrations/activemq/ |
| Datadog Operator | https://github.com/DataDog/datadog-operator |
| Helm chart | https://github.com/DataDog/helm-charts |
| Tagging best practices | https://docs.datadoghq.com/tagging/assigning_tags/ |
| Agent config reference | https://github.com/DataDog/datadog-agent/blob/main/pkg/config/config_template.yaml |
| Datadog SAML SSO | https://docs.datadoghq.com/account_management/saml/ |
| SAML role mapping | https://docs.datadoghq.com/account_management/saml/mapping/ |
| Trace data security (PII) | https://docs.datadoghq.com/tracing/configure_data_security/ |
