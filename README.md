# Finance Sample App — Datadog Observability

A hands-on observability learning environment built on a realistic financial platform. Six microservices spanning Python, Java, Node.js, and Go — pre-wired for Datadog but shipping with all instrumentation **commented out** so engineers can enable each layer progressively.

---

## Architecture

```
                     ┌──────────────────────────────────────────────────────┐
                     │              traffic-generator (in-cluster)           │
                     │    Continuous realistic load — always running         │
                     └────────────────────────┬─────────────────────────────┘
                                              │
                     ┌────────────────────────▼─────────────────────────────┐
                     │                  NGINX (reverse proxy)                │
                     └────────────────────────┬─────────────────────────────┘
                                              │
                     ┌────────────────────────▼─────────────────────────────┐
                     │            gateway-api  (Python / FastAPI)            │
                     │          REST API · OIDC auth middleware · :8080      │
                     └──────────────────┬───────────────────┬───────────────┘
                                        │                   │
          ┌─────────────────────────────▼──┐   ┌───────────▼────────────────────┐
          │  account-service               │   │  transaction-service            │
          │  Java / Spring Boot · :8081    │   │  Node.js / Express · :8082      │
          │  Account CRUD · balance        │   │  Payment initiation · ledger    │
          └────────────────┬───────────────┘   └──────────┬─────────────────────┘
                           │  JMS → fraud.score.queue      │  JMS → alert.queue
                           │                               │
                     ┌─────▼───────────────────────────────▼───────────────┐
                     │           ActiveMQ Artemis  (JMS 2.0 broker)         │
                     └────────────────┬──────────────────────┬──────────────┘
                                      │                      │
               ┌──────────────────────▼────┐    ┌───────────▼──────────────────┐
               │  fraud-detection (Python)  │    │  notification-service (Go)   │
               │  Async scoring consumer    │    │  Email / SMS stub consumer   │
               └───────────────────────────┘    └──────────────────────────────┘

                     ┌──────────────────────────────────────────────────────┐
                     │      batch-processor  (Java / Spring Batch)          │
                     │  Nightly reconciliation · end-of-day settlement       │
                     └──────────────────────────┬───────────────────────────┘
                                                │
                     ┌──────────────────────────▼───────────────────────────┐
                     │     PostgreSQL  (ledger DB)   Redis  (session cache)  │
                     └──────────────────────────────────────────────────────┘
```

---

## Services

| Service | Language | Port | Role |
|---|---|---|---|
| `gateway-api` | Python (FastAPI) | 8080 | Public REST API, OIDC auth, request routing |
| `account-service` | Java (Spring Boot) | 8081 | Account CRUD, balance enquiry, JMS producer |
| `transaction-service` | Node.js (Express) | 8082 | Payment initiation, ledger write, JMS producer |
| `fraud-detection` | Python | — | Async fraud scoring, JMS consumer |
| `notification-service` | Go | — | Async email/SMS stubs, JMS consumer |
| `batch-processor` | Java (Spring Batch) | — | Nightly reconciliation and settlement |
| `traffic-generator` | Python | — | In-cluster continuous load generator |

Supporting infrastructure:

| Component | Image | Purpose |
|---|---|---|
| PostgreSQL 15 | `postgres:15` | Primary ledger database |
| Redis 7 | `redis:7` | Session store and cache |
| ActiveMQ Artemis | `apache/activemq-artemis` | JMS 2.0 broker (mirrors IBM MQ / TIBCO patterns) |
| | `quay.io/keycloak/keycloak:26.0` | OIDC for gateway-api · SAML SSO for Datadog |
| NGINX | `nginx:1.25` | Reverse proxy · frontend dashboard |

---

## Prerequisites

The app runs on Kubernetes. You need either a local cluster or an AWS account.

### Option A — Local Kubernetes (recommended)

| Tool | Install | Notes |
|---|---|---|
| **Docker Desktop** | Enable Kubernetes in Docker Desktop → Settings → Kubernetes | Simplest — images built locally are available in the cluster automatically. |
| **Rancher Desktop** | https://rancherdesktop.io | Good Docker Desktop alternative — images available automatically. |
| **kind** | `brew install kind && kind create cluster` | Kubernetes-in-Docker, popular for CI. |
| **k3d** | `brew install k3d && k3d cluster create finance` | k3s in Docker. Fast startup. |
| **minikube** | `brew install minikube && minikube start` | Feature-rich, good driver support. |

**Docker Desktop quickstart:**
```bash
# 1. Open Docker Desktop → Settings → Kubernetes → Enable Kubernetes → Apply
# 2. Install kubectl and helm
brew install kubectl helm
kubectl get nodes   # 1 node Ready
```

> **Image availability by tool:**
> - **Docker Desktop / Rancher Desktop** — images built with `docker build` are available inside the cluster immediately. No extra step needed.
> - **kind** — `kind load docker-image finance-sample-app-<svc>:latest`
> - **k3d** — `k3d image import finance-sample-app-<svc>:latest`
> - **minikube** — `minikube image load finance-sample-app-<svc>:latest`

### Option B — AWS EKS

Requires AWS CLI ≥ 2.x, Terraform ≥ 1.5, and an SSO profile (`aws configure sso`). See [AWS EKS section](#aws--eks-via-terraform).

### Common tools

```bash
brew install kubectl helm
kubectl version --client && helm version
```

You also need a **Datadog account** with:
- API key: https://app.datadoghq.com/organization-settings/api-keys
- App key: https://app.datadoghq.com/organization-settings/application-keys

Add both to `.env` (copied from `.env.example` — git-ignored):
```bash
cp .env.example .env
# set DD_API_KEY and DD_APP_KEY
```

---

## Credentials

All credentials for local development are pre-set in `.env` and `deploy/kubernetes/base/02-secrets.yaml`. No manual substitution needed for the first run — just `make deploy-k8s`.

### Application credentials

| Component | What | Value | Used by |
|---|---|---|---|
| PostgreSQL | database | `ledger` | account-service, batch-processor |
| PostgreSQL | user | `finance` | account-service, batch-processor |
| PostgreSQL | password | `finance_dev_password` | account-service, batch-processor |
| ActiveMQ Artemis | user | `admin` | all JMS producers/consumers |
| ActiveMQ Artemis | password | `artemis_dev_password` | all JMS producers/consumers |
| Keycloak | admin user | `admin` | Keycloak admin console |
| Keycloak | admin password | `Finance@Admin2025!` | Keycloak admin console |
| Keycloak | finance realm client | `finance-gateway` | gateway-api, frontend dashboard |
| Keycloak | client secret | `FuX1ZIddFs02LzJT-s5MZufplT7SzGmflb42_6P8VcI` | gateway-api, frontend dashboard |

### Access URLs

| What | URL | Notes |
|---|---|---|
| **Finance dashboard** | `http://localhost:30080` | Login with any finance realm user below |
| **Keycloak admin console** | `https://localhost:30443/admin/master/console/#/finance` | Login as `admin` / `Finance@Admin2025!` |
| **Keycloak finance realm account** | `https://localhost:30443/realms/finance/account/` | Self-service account page for realm users |
| **ActiveMQ management console** | `kubectl port-forward svc/activemq-artemis 8161:8161 -n finance` then `http://localhost:8161` | Broker metrics and queue management (not proxied through nginx) |

### Finance realm users and roles

Pre-imported into the `finance` Keycloak realm. Log in via the Finance dashboard at `http://localhost:30080` — it redirects to Keycloak at `https://localhost:30443` automatically.

All users share the password **`Finance@2025!`**.

| Username | Role | Dashboard capabilities |
|---|---|---|
| `alice.analyst` | `finance-analyst` | View accounts list · Check balances · Read-only |
| `bob.trader` | `finance-trader` | Everything analyst can do · **Initiate payments** · **Initiate transfers** |
| `carol.admin` | `finance-admin` | Everything trader can do · **Make deposits** · **Approve/reject payments** · Create accounts |
| `dave.auditor` | `finance-auditor` | View accounts list · Check balances · Read-only |
| `eve.compliance` | `finance-compliance` | View accounts · **Approve or reject pending payments** |

#### What each dashboard card shows per role

| Dashboard card | analyst | trader | admin | auditor | compliance |
|---|---|---|---|---|---|
| Account list | ✅ | ✅ | ✅ | ✅ | ✅ |
| Balance check | ✅ | ✅ | ✅ | ✅ | ✅ |
| Initiate payment | ❌ | ✅ | ✅ | ❌ | ❌ |
| Initiate transfer | ❌ | ✅ | ✅ | ❌ | ❌ |
| Make deposit | ❌ | ❌ | ✅ | ❌ | ❌ |
| Payment validation | ❌ | ❌ | ✅ | ❌ | ✅ |

### Datadog credentials

Set in `.env` — read automatically by `make create-dd-secret`:

| Key | Where to get it |
|---|---|
| `DD_API_KEY` | https://app.datadoghq.com/organization-settings/api-keys |
| `DD_APP_KEY` | https://app.datadoghq.com/organization-settings/application-keys |
| `DATADOG_DBM_PASSWORD` | Password you set for the PostgreSQL `datadog` monitoring user (Step 8 in INSTRUMENTATION.md) |

> **Security:** `.env` is git-ignored and must never be committed. All values in `02-secrets.yaml` are development-only defaults — rotate everything before any staging or production deployment.

---

## Quick Start

The app runs cleanly with no Datadog config. No API key needed for the first run.

```bash
# 1. Build all service images
make build

# 2. Load images into the cluster (skip this step on Docker Desktop / Rancher Desktop)
# kind:     kind load docker-image finance-sample-app-<svc>:latest
# k3d:      k3d image import finance-sample-app-<svc>:latest
# minikube: minikube image load finance-sample-app-<svc>:latest
# Colima:   docker save finance-sample-app-<svc>:latest | colima ssh -- sudo ctr image import -

# 3. Deploy
make deploy-k8s
```

The stack is ready when all pods are Running:
```bash
kubectl get pods -n finance
```

Traffic starts flowing automatically from the in-cluster `traffic-generator` pod:
```bash
kubectl logs -n finance deploy/traffic-generator -f
```

**Finance dashboard:** `http://localhost:30080` — log in with any finance realm user (e.g. `carol.admin` / `Finance@2025!`).

**Keycloak admin console:** `https://localhost:30443/admin/master/console/#/finance` — log in as `admin` / `Finance@Admin2025!`.

See [Credentials](#credentials) for all users, roles, and URLs.

---

## Adding Datadog

```bash
# Deploy the Datadog Agent (creates the secret automatically from .env, then deploys Operator + DaemonSet)
make deploy-k8s-dd
```

APM traces, logs, and metrics appear in Datadog within ~2 minutes. No code changes needed — the Admission Controller injects the tracer library automatically via init containers.

Watch traces flowing:
```bash
kubectl exec -n datadog daemonset/datadog-agent -c trace-agent -- agent status | grep "Traces received"
```

> **Note:** `make test` and `make test-traffic` connect to services from your laptop and require active port-forwards. Since `scripts/port-forward.sh` was removed, run these manually first:
> ```bash
> kubectl port-forward svc/gateway-api 8080:8080 -n finance &
> kubectl port-forward svc/account-service 8081:8081 -n finance &
> kubectl port-forward svc/transaction-service 8082:8082 -n finance &
> kubectl port-forward svc/keycloak 8089:8080 -n finance &
> ```
> Alternatively, the in-cluster `traffic-generator` pod generates continuous traffic automatically — no port-forward needed.

---

## Traffic Generator

Traffic is generated **automatically** by the `traffic-generator` Deployment running inside the cluster. It starts with the app and runs continuously — no scripts needed from your laptop.

```bash
# Watch live traffic
kubectl logs -n finance deploy/traffic-generator -f

# Pause traffic
kubectl scale deployment traffic-generator --replicas=0 -n finance

# Resume
kubectl scale deployment traffic-generator --replicas=1 -n finance

# Tune rate (edit the TRAFFIC_RATE env var)
kubectl set env deployment/traffic-generator TRAFFIC_RATE=5 -n finance
```

Traffic mix:

| Scenario | Weight | Path |
|---|---|---|
| Balance check (JWT) | 30 % | gateway-api → account-service |
| Payment initiation (JWT) | 25 % | gateway-api → transaction-service → ActiveMQ |
| Account lookup (direct) | 20 % | account-service → PostgreSQL |
| Health checks | 10 % | all three HTTP services |
| Error cases (404 / 401 / 422) | 15 % | various |

---

## Instrumentation

See **[INSTRUMENTATION.md](./INSTRUMENTATION.md)** for the complete step-by-step guide.

Summary of what gets enabled:

| Step | Signal | How |
|---|---|---|
| 1 | Structured JSON logs | Always active — `ad.datadoghq.com/*.logs` annotations |
| 2 | Unified Service Tags | Always active — `DD_ENV`, `DD_SERVICE`, `DD_VERSION` env vars |
| 3 | APM traces | Automatic — Admission Controller injects tracer at pod start |
| 4 | Log–trace correlation | Automatic with Layer 1 — `dd.trace_id` in every log line |
| 5 | Custom business spans | `make instrument` — uncomments span code in each service |
| 6 | DogStatsD metrics | `make instrument` — `finance.payment.initiated` etc. |
| 7 | Continuous Profiler | `DD_PROFILING_ENABLED=true` per service |
| 8 | Database Monitoring | Agent check — `deploy/kubernetes/datadog/checks/postgres-check.yaml` |
| 9 | ActiveMQ JMX | Agent check — `deploy/kubernetes/datadog/checks/activemq-check.yaml` |
| 10 | Terraform resources | `make tf-apply-dd` — monitors, SLOs, dashboard, synthetics |
| 11 | Synthetic tests | Included in Terraform — 7 tests from real APM traffic |
| 12 | ASM + CWS + CSPM | Agent-side — enabled in `datadog-agent.yaml` |

---

## Deployment Targets

```
deploy/
  kubernetes/
    base/          K8s manifests shared by all targets
    datadog/       Datadog Agent overlay (Operator CRD, checks, secrets)
    overlays/eks/  Kustomize patches for EKS (ECR images, LoadBalancer)
  terraform/
    aws/           EKS + ECR + VPC + IAM + Secrets Manager
    datadog/       Monitors, SLOs, dashboard, synthetic tests
    gcp/           GKE — scaffolded, not yet tested
```

### Local Kubernetes (Docker Desktop / kind / k3d / minikube)

```bash
make build
# load images if needed — see Prerequisites above (skip on Docker Desktop)
make deploy-k8s       # deploys app + traffic-generator
make deploy-k8s-dd    # creates Datadog secret from .env then deploys Agent
make teardown         # full reset (namespaces + volumes)
```

### AWS EKS via Terraform

```bash
# 1. Authenticate
aws sso login --profile <your-profile>

# 2. Configure Terraform
cp deploy/terraform/aws/staging.tfvars.example deploy/terraform/aws/staging.tfvars
# edit: aws_profile, aws_region, cluster_name

# 3. Provision AWS infrastructure (~15–20 min)
#    Creates: EKS cluster, VPC, ECR repos, IAM roles, Secrets Manager entries
make tf-plan-aws
make tf-apply-aws

# 4. Configure kubectl
make tf-configure-kubectl
kubectl get nodes   # verify cluster is reachable

# 5. Build and push images to ECR (cross-compile for linux/amd64 on Apple Silicon)
eval "$(cd deploy/terraform/aws && terraform output -raw ecr_login_command)"
make build-ecr

# 6. Deploy the app (EKS overlay: ECR images + LoadBalancer for frontend + Keycloak)
make deploy-k8s-eks

# 6b. Set the Keycloak public URL once the NLB hostname is assigned (~2 min)
#     Keycloak is exposed via its own NLB (not proxied through nginx).
#     KEYCLOAK_PUBLIC_URL in app-config drives both KC_HOSTNAME_URL on the
#     Keycloak pod and the KEYCLOAK_BASE variable in the finance dashboard.
KC_HOST=$(kubectl get svc keycloak -n finance -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
kubectl patch configmap app-config -n finance --type=merge \
  -p "{\"data\":{\"KEYCLOAK_PUBLIC_URL\":\"http://$KC_HOST\"}}"
kubectl rollout restart deployment/keycloak deployment/frontend -n finance
# Dashboard: http://$(kubectl get svc frontend -n finance -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
# Keycloak:  http://$KC_HOST/admin/master/console/#/finance

# 7. Add Datadog (auto-fetches keys from Secrets Manager)
#    Prerequisites: deploy/terraform/aws/staging.tfvars must have aws_region + aws_profile.
#    Populate secrets first if not done:
#    aws secretsmanager put-secret-value --secret-id finance-app/staging/dd-api-key \
#      --secret-string "<key>" --profile <profile> --region <region>
make deploy-k8s-dd

# 8. Apply Datadog Terraform resources
eval "$(make dd-secrets)"
make tf-apply-dd

# 9. Enable Layer 2 instrumentation
make instrument
make build-ecr
make deploy-k8s-eks
kubectl rollout restart deployment -n finance

# 10. Tear down when done
make tf-destroy-aws   # handles ELB release, node groups, ECR, VPC in correct order
```

#### Teardown order matters on EKS

`make tf-destroy-aws` handles dependency ordering automatically:

| Step | Action | Why |
|---|---|---|
| 0 | Delete `finance` namespace | Releases AWS ELB — without this, VPC deletion fails |
| 1 | Delete EKS node groups via CLI | Avoids `ResourceInUseException` |
| 2 | Delete EKS add-ons via CLI | Required before cluster deletion |
| 3 | Delete EKS cluster | |
| 4 | Force-delete Secrets Manager secrets | Avoids re-apply failures |
| 5 | `terraform destroy` | VPC, subnets, IAM, KMS, CloudWatch |

### GCP GKE *(coming soon)*

Scaffolded in `deploy/terraform/gcp/` — not yet tested end-to-end. See `deploy/terraform/gcp/README.md`.

---

## Teardown (local)

```bash
make teardown
```

Removes: finance + datadog namespaces (including all PVCs), Datadog Operator Helm release, and any orphaned Docker volumes from previous Compose runs.

Start fresh after:
```bash
make build && make deploy-k8s && make deploy-k8s-dd
```

---

## Security Notes

- **Secrets:** `DD_API_KEY` and `DD_APP_KEY` are never committed. Local: stored in `.env` (git-ignored), loaded by `make create-dd-secret`. EKS: fetched from AWS Secrets Manager automatically.
- **K8s Secret:** `datadog-secret` in the `datadog` namespace holds `api-key`, `app-key`, and `dbm-password`. Created by `make create-dd-secret`.
- **PII masking:** Financial data (card numbers, IBANs, account balances) must not appear in trace tags or log messages. Configure `obfuscation_config` and `replace_tags` in the Agent for production.
- **DBM user:** The PostgreSQL monitoring user must be read-only (`pg_monitor` role only). Setup SQL is in the header of `deploy/kubernetes/datadog/checks/postgres-check.yaml`.
- **RUM Session Replay:** The frontend enables `defaultPrivacyLevel: 'mask-user-input'` — do not disable for environments with real financial data.
- **Keycloak:** Sample passwords in `identity-provider/realm-export/` are for development only. Rotate before any staging or production use.

---

## Identity Provider

Keycloak **26.0** provides:
- **OIDC for gateway-api** — JWT Bearer token validation per request
- **SAML 2.0 SSO for Datadog** — mirrors enterprise IdPs (Okta, Azure AD, PingFederate)
- **Finance roles** — `finance-analyst`, `finance-trader`, `finance-admin`, `finance-auditor`, `finance-compliance`

Keycloak is proxied through **nginx over HTTPS** on port **30443** — nginx terminates TLS with a self-signed certificate and forwards plain HTTP to `keycloak:8080` internally. This allows Keycloak 26 to set `Secure` session cookies correctly (required by browsers).

> **First visit:** browsers will show a security warning for the self-signed certificate at `https://localhost:30443`. Click **Advanced → Accept the Risk** (Firefox) or **Advanced → Proceed** (Chrome) once — you won't be asked again.

`KEYCLOAK_PUBLIC_URL` in `deploy/kubernetes/base/01-config.yaml` is the single source of truth for Keycloak's public URL. It is used by `KC_HOSTNAME_URL` on the Keycloak pod and injected into the finance dashboard at deploy time. On EKS, patch it to the NLB hostname after deploy (see AWS EKS workflow above).

| URL | Credentials |
|---|---|
| **Admin console:** `https://localhost:30443/admin/master/console/#/finance` | `admin` / `Finance@Admin2025!` |
| **Realm account page:** `https://localhost:30443/realms/finance/account/` | any finance realm user |

Full guide: `identity-provider/README.md`

---

## Key Datadog Documentation

| Topic | URL |
|---|---|
| Unified Service Tagging | https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/ |
| Single-step instrumentation | https://docs.datadoghq.com/tracing/trace_collection/automatic_instrumentation/single-step-apm/ |
| APM setup | https://docs.datadoghq.com/tracing/trace_collection/ |
| Log correlation | https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/ |
| DogStatsD custom metrics | https://docs.datadoghq.com/developers/dogstatsd/ |
| Continuous Profiler | https://docs.datadoghq.com/profiler/ |
| Database Monitoring | https://docs.datadoghq.com/database_monitoring/ |
| DBM — PostgreSQL self-hosted | https://docs.datadoghq.com/database_monitoring/setup_postgres/selfhosted/ |
| Data Streams Monitoring | https://docs.datadoghq.com/data_streams/ |
| Data Jobs Monitoring | https://docs.datadoghq.com/data_jobs/ |
| Synthetic Monitoring | https://docs.datadoghq.com/synthetics/ |
| Application Security (ASM) | https://docs.datadoghq.com/security/application_security/ |
| Cloud Workload Security (CWS) | https://docs.datadoghq.com/security/cloud_workload_security/ |
| Cloud Security Management | https://docs.datadoghq.com/security/cloud_security_management/ |
| ActiveMQ integration | https://docs.datadoghq.com/integrations/activemq/ |
| Datadog Operator | https://github.com/DataDog/datadog-operator |
| Tagging best practices | https://docs.datadoghq.com/tagging/assigning_tags/ |
| Trace data security (PII) | https://docs.datadoghq.com/tracing/configure_data_security/ |
| Datadog SAML SSO | https://docs.datadoghq.com/account_management/saml/ |
