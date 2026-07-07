# Finance Sample App — Datadog Observability

A hands-on observability learning environment built on a realistic financial platform. Six microservices spanning Python, Java, Node.js, and Go — pre-wired for Datadog but shipping with all instrumentation **commented out** so engineers can enable each layer progressively.

> Something not working? See **[TROUBLESHOOTING.md](./TROUBLESHOOTING.md)** for a layer-by-layer diagnostic model (Infrastructure → Application → Identity → Instrumentation → Telemetry → Backend) instead of chasing symptoms.

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
> - **Colima (with Kubernetes)** — its k3s uses containerd, so import into the `k8s.io` namespace (not just Docker): `docker save finance-sample-app-<svc>:latest | colima ssh -- sudo ctr -n k8s.io image import -`

> **NOTE**
> Please note that synthetics test will not work with local k8s unless you set up internal location as your network is not reachable by public cloud.

### Option B — AWS EKS

Additionally requires AWS CLI ≥ 2.x and an SSO profile (`aws configure sso`). See [AWS EKS section](#aws--eks-via-terraform).

### Common tools

Required for **both** local and AWS EKS — Terraform isn't just for AWS: it's also
how you apply the Datadog resources (monitors, dashboard, synthetics, log
pipeline) via `make tf-apply-dd`, regardless of where the app itself runs.

```bash
brew install kubectl helm terraform
kubectl version --client && helm version && terraform version   # >= 1.5
```

You also need a **Datadog account** with:
- API key: https://app.datadoghq.com/organization-settings/api-keys
- App key: https://app.datadoghq.com/organization-settings/application-keys

> ⚠️ **Application Key value, not Application Key ID.** The Application Keys page
> prominently shows the **Key ID** in the main list — that is NOT what you want.
> Click into the key (or use the "copy" icon next to a *newly created* key) to
> reveal the actual **key value**, a much longer string. Using the Key ID for
> `DD_APP_KEY` / `TF_VAR_datadog_app_key` causes `401 Unauthorized` errors on
> every Terraform apply, with no indication of what's actually wrong.
> ```
> DD_APP_KEY=ddapp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx   ✅ correct (key VALUE)
> DD_APP_KEY=a1b2c3d4-e5f6-7890-abcd-ef1234567890             ❌ wrong (key ID — looks like a UUID)
> ```

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
| `DATADOG_DBM_PASSWORD` | Password you set for the PostgreSQL `datadog` monitoring user (Step 9 in INSTRUMENTATION.md) |

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
# Colima:   docker save finance-sample-app-<svc>:latest | colima ssh -- sudo ctr -n k8s.io image import -

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

> #### ✅ Verify before continuing
> - [ ] `kubectl get pods -n finance` — all 12 pods `Running` (incl. `traffic-generator`)
> - [ ] `kubectl logs -n finance deploy/traffic-generator -f` — shows successful (non-401) requests
> - [ ] Finance dashboard loads at `http://localhost:30080` and login succeeds
>
> If the traffic generator logs show `401` / `invalid_client_credentials`, the
> `KEYCLOAK_CLIENT_SECRET` env var on the `traffic-generator` Deployment doesn't
> match the real `app-secrets` secret — check `kubectl get deployment
> traffic-generator -n finance -o yaml | grep -A3 KEYCLOAK_CLIENT_SECRET`.

---

## Adding Datadog

```bash
# Deploy the Datadog Agent (creates the secret automatically from .env, then deploys Operator + DaemonSet)
make deploy-k8s-dd
```

APM traces, logs, and metrics appear in Datadog within ~2 minutes. No code changes needed — the Admission Controller injects the tracer library automatically via init containers.

> #### ✅ Verify before continuing
> - [ ] `kubectl get pods -n datadog` — Agent DaemonSet pods and `datadog-cluster-agent` all `Running`
> - [ ] `kubectl get datadogagent -n datadog` — shows `Running` for both Agent and ClusterAgent
> - [ ] Admission Controller enabled: `kubectl get pod -n finance -l app=gateway-api -o jsonpath='{.items[0].spec.initContainers[*].name}'` — shows `datadog-lib-python-init` (or the equivalent per-language init container)
>
> If init containers are missing, see [INSTRUMENTATION.md's Admission Controller troubleshooting](./INSTRUMENTATION.md#admission-controller-injection-not-working).

Watch traces flowing:
```bash
kubectl exec -n datadog daemonset/datadog-agent -c trace-agent -- agent status | grep "Traces received"
```

> #### ✅ Verify before continuing
> - [ ] `agent status | grep "Traces received"` shows a non-zero count
> - [ ] APM > Services in Datadog shows all 6 services within ~2 minutes
> - [ ] Clicking into a trace shows a connected flame graph across services (e.g. `gateway-api` → `account-service`)

> **Note:** `make test` / `make test-traffic` run from your laptop and need manual port-forwards first — see [INSTRUMENTATION.md's Makefile targets](./INSTRUMENTATION.md#makefile-targets) for the commands. You normally don't need either: the in-cluster `traffic-generator` pod already generates continuous traffic with no port-forward required.

---

## Traffic Generator

Traffic is generated **automatically** by the `traffic-generator` Deployment running inside the cluster. It starts with the app and runs continuously — no scripts needed from your laptop. See [INSTRUMENTATION.md's Traffic Generator section](./INSTRUMENTATION.md#traffic-generator) for the watch/pause/resume/tune-rate commands.

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

Instrumentation is layered. Full guide: **[INSTRUMENTATION.md](./INSTRUMENTATION.md)**.

- **Layer 1 — automatic.** Deploy the Agent (`make deploy-k8s-dd`) and the Admission Controller injects the tracer into every pod: APM traces, log–trace correlation, and runtime metrics, plus agent-side DBM, ActiveMQ JMX, and ASM/CWS/CSPM. No code changes.
- **Layer 2 — `make instrument`.** Uncomments the `transaction-service` `payment.authorize` span and injects Browser RUM credentials. (Other custom spans are always-on in source; **custom metrics are span-based**, created by `make tf-apply-dd` — no DogStatsD.) See [Enabling Layer 2](./INSTRUMENTATION.md#enabling-layer-2-make-instrument).
- **Datadog resources.** `make tf-apply-dd` creates the monitors, SLOs, dashboard, synthetics, log pipeline, and the RUM application.

> ⚠️ **Browser RUM requires `make tf-apply-dd` before `make instrument`** — it injects the RUM credentials that Terraform creates. Backend patches apply either way; if you instrument first, just re-run `make instrument` after `tf-apply-dd` (idempotent).

Per-signal breakdown and validation steps: [INSTRUMENTATION.md → Signal reference](./INSTRUMENTATION.md#signal-reference).

---

## Testing everything manually

The fastest way to exercise the whole stack end-to-end. Every target is
idempotent — safe to re-run. For what "healthy" looks like at each phase, use the
**✅ Verify before continuing** checklists in [Quick Start](#quick-start) and
[Adding Datadog](#adding-datadog).

### Local (Docker Desktop / Rancher / kind / k3d / minikube / Colima)

```bash
make build                     # build the 6 service images

# Load images into the cluster (see Prerequisites for your tool):
#   Docker Desktop / Rancher Desktop — automatic, skip this step
#   Colima (its Kubernetes uses containerd) — import into the k8s.io namespace:
#     for svc in gateway-api account-service transaction-service fraud-detection notification-service batch-processor; do \
#       docker save "finance-sample-app-${svc}:latest" | colima ssh -- sudo ctr -n k8s.io image import -; done
#   kind: kind load docker-image …   k3d: k3d image import …   minikube: minikube image load …

make deploy-k8s                # app + in-cluster traffic generator
kubectl get pods -n finance    # wait for all 12 pods Running
make deploy-k8s-dd             # Datadog Agent (reads DD_API_KEY / DD_APP_KEY from .env)

# Datadog Terraform resources — RUM app, monitors, SLOs, dashboard, synthetics.
# Run this BEFORE 'make instrument' so the RUM credentials exist (see Instrumentation note).
cp deploy/terraform/datadog/staging.tfvars.example deploy/terraform/datadog/staging.tfvars   # first time only
eval "$(make dd-secrets)"       # exports TF_VAR_* keys; locally reads DD_API_KEY / DD_APP_KEY from .env
                                # (falls back to .env even if you're logged into AWS)
make tf-apply-dd

# Layer 2 — transaction-service payment.authorize span + Browser RUM
# (custom metrics are span-based via 'make tf-apply-dd' — no DogStatsD)
make instrument                # injects RUM creds from the tf-apply-dd output above
make build                     # rebuild, then reload images (see load step) and restart:
kubectl rollout restart deployment -n finance
make uninstrument              # reverse Layer 2 at any time

make teardown                  # full local cleanup (namespaces + volumes)
make tf-destroy-dd             # remove the Datadog Terraform resources when done
```

> **Local log-index note:** the Datadog log index created by `make tf-apply-dd` filters on
> `kube_cluster_name:finance-app`. A local cluster usually reports a different cluster name, so
> local logs may not land in that dedicated index — APM, monitors, dashboard, synthetics, and RUM
> all still work regardless.

### AWS EKS

```bash
aws sso login --profile <profile>
make tf-plan-aws && make tf-apply-aws            # provisions EKS/VPC/ECR/IAM/NLB (~15–20 min)
make tf-configure-kubectl && kubectl get nodes
eval "$(cd deploy/terraform/aws && terraform output -raw ecr_login_command)"
make build-ecr && make deploy-k8s-eks
# then point Keycloak at the NLB — run the numbered step 8 block under "AWS EKS via Terraform" below
make deploy-k8s-dd                               # pulls DD keys from AWS Secrets Manager
eval "$(make dd-secrets)" && make tf-apply-dd
make tf-destroy-aws                              # single-command teardown when done
```

### How to confirm it works

| Check | Where to look |
|---|---|
| App is serving traffic | `kubectl logs -n finance deploy/traffic-generator -f` — 200/201 responses, no 401 storms |
| Dashboard + login | `http://localhost:30080` (EKS: `cd deploy/terraform/aws && terraform output -raw frontend_url`) — log in as `carol.admin` / `Finance@2025!` |
| Scripted e2e test | `make test` (needs a port-forward — see [INSTRUMENTATION.md](./INSTRUMENTATION.md#makefile-targets)) |
| APM traces | Datadog → **APM → Services** (filter `env:staging`); open a trace → connected flame graph across services |
| Log–trace correlation | Datadog → **Logs** — every line carries `dd.trace_id` / `dd.service` |
| Async pipeline & DB | **Data Streams** (JMS producer→consumer), **Database Monitoring** (Postgres query metrics) |

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

# 6. (Optional) Configure a custom domain + ACM certificate for HTTPS on the NLB.
#    Without this, the dashboard is HTTP-only at the NLB hostname (fine for a demo).
#    Edit staging.tfvars: domain_name = "finance.example.com", then make tf-apply-aws,
#    then add a CNAME in your DNS: finance.example.com → <nlb-hostname>.
#    See deploy/terraform/aws/variables.tf for domain_name.

# 7. Deploy the app to EKS (generates the Kustomize overlay from live Terraform
#    output — ECR image URLs, ACM cert annotations if domain_name is set)
make deploy-k8s-eks

# 8. Point Keycloak's public URL at the Terraform-managed NLB.
#    The NLB (aws_lb.frontend) was already created in step 3, so its hostname is
#    known immediately — no waiting for AWS to assign a LoadBalancer hostname like
#    the old Kubernetes-provisioned ELB required.
FE_URL=$(cd deploy/terraform/aws && terraform output -raw frontend_url)
kubectl patch configmap app-config -n finance --type=merge \
  -p "{\"data\":{\"KEYCLOAK_PUBLIC_URL\":\"$FE_URL\"}}"
sed "s|https://localhost:30443|$FE_URL|g" frontend-stub/index.html > /tmp/finance-index.html
kubectl create configmap frontend-dashboard --from-file=index.html=/tmp/finance-index.html \
  -n finance --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/keycloak deployment/frontend -n finance
# Dashboard: terraform output -raw frontend_url
# Keycloak (self-signed passthrough, always available): terraform output -raw frontend_keycloak_https_url

# 9. Add Datadog (auto-fetches keys from Secrets Manager)
#    Prerequisites: deploy/terraform/aws/staging.tfvars must have aws_region + aws_profile.
#    Populate secrets first if not done:
#    aws secretsmanager put-secret-value --secret-id finance-app/staging/dd-api-key \
#      --secret-string "<key>" --profile <profile> --region <region>
make deploy-k8s-dd

# 10. Apply Datadog Terraform resources
eval "$(make dd-secrets)"
make tf-apply-dd

# 11. Enable Layer 2 instrumentation
make instrument
make build-ecr
make deploy-k8s-eks
kubectl rollout restart deployment -n finance

# 12. Tear down when done
make tf-destroy-aws   # single-pass terraform destroy — see below for why this is now reliable
```

#### Teardown is reliable — no manual ELB cleanup needed

`make tf-destroy-aws` (→ `scripts/aws-force-destroy.sh`) handles dependency ordering automatically:

| Step | Action | Why |
|---|---|---|
| 0 | Best-effort ELB/security-group safety net | Defense-in-depth only — normally a no-op (see below) |
| 1 | Delete EKS node groups via CLI | Avoids `ResourceInUseException` |
| 2 | Delete EKS add-ons via CLI | Required before cluster deletion |
| 3 | Delete EKS cluster | |
| 4 | Force-delete Secrets Manager secrets | Avoids re-apply failures |
| 5 | Delete ECR repositories | |
| 6 | `terraform destroy` | VPC, subnets, IAM, KMS, CloudWatch, the frontend NLB, target groups |

> **Why teardown no longer needs manual ELB cleanup:** the `frontend` Service is `type: NodePort` on both local and EKS — it never calls the AWS API. Public exposure is handled entirely by `aws_lb.frontend`, a first-class Terraform resource, so `terraform destroy` always finds and removes it in the correct dependency order. This replaced an older design where `type: LoadBalancer` let Kubernetes' cloud-controller-manager silently create a Classic ELB that Terraform never tracked — if the EKS cluster was deleted first, that ELB (and its security group) became permanently orphaned and blocked VPC/subnet deletion. Step 0 above is kept purely as a defense-in-depth safety net in case a future change reintroduces a `LoadBalancer` Service elsewhere.

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

For the full reference table (APM, DogStatsD, Profiler, DBM, DSM, Data Jobs, RUM, Synthetics, ASM/CWS/CSPM, and more), see [INSTRUMENTATION.md's Key references](./INSTRUMENTATION.md#key-references). Quick links to get started:

| Topic | URL |
|---|---|
| Unified Service Tagging | https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/ |
| Single-step instrumentation | https://docs.datadoghq.com/tracing/trace_collection/automatic_instrumentation/single-step-apm/ |
| APM setup | https://docs.datadoghq.com/tracing/trace_collection/ |
| Datadog SAML SSO | https://docs.datadoghq.com/account_management/saml/ |
