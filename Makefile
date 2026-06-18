# Finance Sample App — Datadog Observability
#
# DD_VERSION is auto-set to the git short SHA for Deployment Tracking.
# This ties every container image to an exact commit so that anomalies
# surfaced in Datadog APM, Profiler, or Data Jobs Monitoring can be
# linked back to a specific release via the Deployment Tracking UI.
# Docs: https://docs.datadoghq.com/tracing/deployment_tracking/
#
# Two Docker Compose files are provided:
#   docker-compose.base.yml    — no Datadog: use this first to verify the app works
#   docker-compose.datadog.yml — adds the Datadog Agent and DD_* env vars to every
#                                service; follow the 12-step Learning Progression
#
# Usage:
#   make build          Build all service images (sets DD_VERSION automatically)
#   make up             Start the stack WITHOUT Datadog (docker-compose.base.yml)
#   make up-dd          Start the stack WITH the Datadog Agent (docker-compose.datadog.yml)
#   make down           Stop and remove containers (base stack)
#   make down-dd        Stop and remove containers (Datadog stack)
#   make logs           Tail logs from all services
#   make health         Check gateway-api /health endpoint
#   make test           Run the end-to-end test suite
#   make version        Print the current DD_VERSION value
#   make deploy-k8s          Apply Kubernetes manifests (no Datadog)
#   make deploy-k8s-dd        Apply Datadog Agent on top of the K8s deployment
#   make tf-plan-aws          Terraform plan for AWS / EKS infrastructure
#   make tf-apply-aws         Terraform apply (creates EKS with Bottlerocket, ECR, VPC, IAM)
#   make tf-configure-kubectl Update kubeconfig for the EKS cluster
#   make deploy-k8s-eks       Deploy the Finance app to EKS
#   make deploy-k8s-dd        Deploy the Datadog Agent (auto-detects local vs EKS)
#   make tf-destroy-aws       Destroy all AWS Terraform resources
#   make tf-force-destroy-aws Force-destroy in dependency order (use when tf-destroy-aws fails)
#   # make tf-plan-gcp        [GCP — not yet available, see deploy/terraform/gcp/]
#
# AWS + K8s workflow:
#   aws sso login --profile <profile>   # authenticate
#   make tf-plan-aws                    # review the plan first
#   make tf-apply-aws                   # provision EKS, ECR, VPC, IAM (~15-20 min)
#   make tf-configure-kubectl           # configure kubectl
#   make build-ecr                      # build & push images for linux/amd64
#   make deploy-k8s-eks                 # deploy app (includes gp3 StorageClass)
#   make deploy-k8s-dd                  # deploy Datadog Agent (auto-detects EKS)
#
# GCP + K8s workflow:  [not yet available — Terraform module scaffolded but untested]
#   # gcloud auth application-default login
#   # make tf-plan-gcp
#   # make tf-apply-gcp
#   # make tf-configure-kubectl-gcp
#   # make deploy-k8s

.PHONY: all build build-ecr up up-dd down down-dd logs health version test test-traffic restart clean-data reset-db deploy-k8s deploy-k8s-eks deploy-k8s-dd undeploy-k8s instrument uninstrument tf-plan-aws tf-apply-aws tf-configure-kubectl frontend-url tf-destroy-aws tf-force-destroy-aws dd-secrets tf-plan-dd tf-apply-dd tf-destroy-dd help

# Resolve DD_VERSION once so all targets share the same value.
# Falls back to 'dev' when git is not available (e.g. in a bare CI image).
DD_VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo 'dev')

# Detect whether Docker Compose V2 plugin ("docker compose") or the
# standalone V1 binary ("docker-compose") is available on this machine.
# V2 is the default on Docker Desktop >= 3.4 and Docker Engine >= 20.10.
DOCKER_COMPOSE := $(shell docker compose version >/dev/null 2>&1 && echo "docker compose" || echo "docker-compose")

# Base stack (no Datadog) — used by make up / make test / make restart etc.
COMPOSE_FILE    := deploy/docker/docker-compose.base.yml
# Datadog stack — used by make up-dd / make down-dd
COMPOSE_FILE_DD := deploy/docker/docker-compose.datadog.yml

all: build

## help: Show this help message (all available make targets with descriptions).
help:
	@echo "Finance Sample App - Datadog Observability"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@awk '/^## [a-zA-Z0-9_-]+:/ { \
			sub(/^## /, ""); \
			split($$0, a, ":"); \
			target=a[1]; \
			sub(/^[^:]*: */, ""); \
			desc=$$0; \
			printf "  \033[36m%-30s\033[0m %s\n", target, desc \
		}' $(MAKEFILE_LIST)
	@echo ""

## version: Print the DD_VERSION that will be embedded in image labels and env vars.
version:
	@echo "DD_VERSION=$(DD_VERSION)"

## instrument: Uncomment all Datadog instrumentation blocks across all services.
##             Applies unified diff patches — fully reversible with make uninstrument.
##             See INSTRUMENTATION.md for what each patch enables.
##
##             After patching, redeploy:
##               Local:  make build && make down && make up-dd
##               EKS:    make build-ecr && make deploy-k8s-eks
##                       kubectl rollout restart deployment -n finance
instrument:
	@echo "Applying instrumentation patches..."
	@for p in scripts/patches/*.patch; do \
		svc=$$(basename $$p .patch); \
		echo "  $$svc"; \
		patch -p1 --forward -s < $$p || true; \
	done
	@echo ""
	@echo "✓ Instrumentation enabled. Redeploy to activate:"
	@echo "   Local: make build && make down && make up-dd"
	@echo "   EKS:   make build-ecr && make deploy-k8s-eks"

## uninstrument: Re-comment all Datadog instrumentation blocks (reverse of make instrument).
##               Restores every file to its original commented-out state.
##
##               After patching, redeploy:
##                 Local:  make build && make down && make up-dd
##                 EKS:    make build-ecr && make deploy-k8s-eks
uninstrument:
	@echo "Reversing instrumentation patches..."
	@for p in scripts/patches/*.patch; do \
		svc=$$(basename $$p .patch); \
		echo "  $$svc"; \
		patch -p1 --reverse -s < $$p || true; \
	done
	@echo ""
	@echo "✓ Instrumentation disabled. Redeploy to deactivate:"
	@echo "   Local: make build && make down && make up-dd"
	@echo "   EKS:   make build-ecr && make deploy-k8s-eks"

## build: Build all service images for the LOCAL platform (use for Docker Compose / Colima).
build:
	DD_VERSION=$(DD_VERSION) $(DOCKER_COMPOSE) -f $(COMPOSE_FILE) build

## build-ecr: Build all service images for linux/amd64 and push directly to ECR.
##            Use this when deploying to EKS from an Apple Silicon (ARM) Mac.
##            Requires: ECR login (eval "$(cd deploy/terraform/aws && terraform output -raw ecr_login_command)")
##            Uses Docker Buildx cross-compilation — no QEMU emulation, safe on ARM.
##            Requires: terraform apply must have completed (make tf-apply-aws)
build-ecr:
	@if [ ! -f deploy/terraform/aws/staging.tfvars ]; then \
		echo "Error: deploy/terraform/aws/staging.tfvars not found."; \
		echo "       Copy staging.tfvars.example and fill in your values first."; \
		exit 1; \
	fi
	@cd deploy/terraform/aws && terraform output ecr_registry_urls >/dev/null 2>&1 || { \
		echo "Error: terraform output ecr_registry_urls failed."; \
		echo "       Run 'make tf-apply-aws' before 'make build-ecr'."; \
		exit 1; \
	}
	@ECR_URLS=$$(cd deploy/terraform/aws && terraform output -json ecr_registry_urls); \
	for SVC in gateway-api account-service transaction-service fraud-detection notification-service batch-processor; do \
		ECR_URL=$$(echo "$$ECR_URLS" | python3 -c "import sys,json; print(json.load(sys.stdin)['$$SVC'])"); \
		echo "Building $$SVC -> $$ECR_URL"; \
		docker buildx build --platform linux/amd64 --push \
			-t $${ECR_URL}:$(DD_VERSION) \
			-t $${ECR_URL}:latest \
			./$$SVC; \
	done

## up: Start the stack WITHOUT Datadog (docker-compose.base.yml).
##     This is the recommended starting point before adding instrumentation.
up:
	DD_VERSION=$(DD_VERSION) $(DOCKER_COMPOSE) -f $(COMPOSE_FILE) up -d

## up-dd: Start the stack WITH the Datadog Agent (docker-compose.datadog.yml).
##        Requires DD_API_KEY to be set in deploy/docker/.env to actually ship
##        telemetry. The app runs cleanly with the agent present but no API key
##        (the agent container will restart but services are unaffected).
##        Follow the 12-step Learning Progression in each service README.
up-dd:
	DD_VERSION=$(DD_VERSION) $(DOCKER_COMPOSE) -f $(COMPOSE_FILE_DD) up -d

## down: Stop and remove all containers for the base stack.
down:
	$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) down

## down-dd: Stop and remove all containers for the Datadog stack.
down-dd:
	$(DOCKER_COMPOSE) -f $(COMPOSE_FILE_DD) down

## logs: Tail combined logs from all running services (Ctrl-C to exit).
logs:
	$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) logs -f

## health: Hit the gateway-api /health endpoint and pretty-print the JSON response.
health:
	curl -s http://localhost:8080/health | python3 -m json.tool

## test: Run the end-to-end test suite against the running stack.
##       Prerequisites: make up (stack must be running and healthy).
##       Uses Python stdlib only — no pip install required.
test:
	python3 scripts/test-e2e.py

## test-traffic: Generate realistic mixed traffic for 60 s at 2 req/s.
##               Useful for populating APM traces and metrics before a demo.
test-traffic:
	python3 scripts/generate-traffic.py --rate 2 --duration 60

## restart: Force-recreate the application containers to flush stale inter-service DNS.
##           Use this when you see 502 errors after individual container restarts.
restart:
	$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) up -d --force-recreate \
		gateway-api account-service transaction-service frontend

## clean-data: Soft reset — clears all in-memory application state.
##             Recreates account-service (Java ConcurrentHashMap) and
##             transaction-service (Node.js Map). The seed account acc-001
##             (EUR 12 500, premium) reappears automatically on restart.
##             PostgreSQL, Redis, and ActiveMQ are untouched.
clean-data:
	@echo "Clearing in-memory state (accounts + payments)..."
	$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) up -d --force-recreate \
		account-service transaction-service
	@echo "\u2713  Done. Accounts and payments reset to seed state (acc-001 restored)."
	@echo "     Run 'make test' to verify the clean state."

## reset-db: Hard reset — drops the PostgreSQL ledger database, flushes Redis,
##           and clears all in-memory service state.
##           The postgres-data Docker volume is removed and recreated from
##           scratch (pg_stat_statements enabled, Spring Batch tables auto-created).
##           Use this when you want a completely clean environment.
##           WARNING: All persisted data is permanently deleted.
reset-db:
	@echo "WARNING: This permanently deletes all database data."
	@echo "Stopping services that depend on PostgreSQL..."
	$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) stop batch-processor account-service
	@echo "Stopping PostgreSQL..."
	$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) stop postgres-ledger
	@echo "Removing postgres-data volume..."
	docker volume rm finance-sample-app_postgres-data 2>/dev/null || true
	@echo "Flushing Redis cache..."
	docker exec redis redis-cli FLUSHALL
	@echo "Restarting PostgreSQL (re-initialises from scratch)..."
	$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) up -d postgres-ledger
	@echo "Waiting for PostgreSQL to be ready (up to 60 s)..."
	@for i in 1 2 3 4 5 6; do \
		sleep 10; \
		docker exec postgres-ledger pg_isready -q 2>/dev/null && echo "  PostgreSQL is ready." && break; \
		echo "  still initialising (attempt $$i/6)..."; \
	done
	@echo "Restarting application services (force-recreate flushes stale DNS)..."
	$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) up -d --force-recreate \
		account-service batch-processor transaction-service gateway-api frontend
	@echo "Allowing services 10 s to complete startup..."
	@sleep 10
	@echo "\u2713  Reset complete."
	@echo "     Run 'make test' to verify the fresh state."

## deploy-k8s: Deploy the Finance app to Kubernetes without Datadog.
##             Creates the 'finance' namespace and all infrastructure + application services.
##             Prerequisites:
##               1. make build        — build all service images
##               2. kubectl configured — pointing at your target cluster
##             On local clusters (Colima with Docker runtime), images built by
##             'make build' are immediately available (imagePullPolicy: IfNotPresent).
deploy-k8s:
	@echo "Creating finance namespace (idempotent)..."
	kubectl apply -f deploy/kubernetes/base/00-namespace.yaml
	@echo "Creating Keycloak realm ConfigMap..."
	kubectl create configmap keycloak-realm-import \
		--from-file=identity-provider/realm-export/ \
		-n finance --dry-run=client -o yaml | kubectl apply -f -
	@echo "Applying config, secrets and infrastructure..."
	kubectl apply -f deploy/kubernetes/base/01-config.yaml
	kubectl apply -f deploy/kubernetes/base/02-secrets.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/
	@echo "Waiting for PostgreSQL to be ready..."
	kubectl rollout status statefulset/postgres-ledger -n finance --timeout=120s
	@echo "Applying application services..."
	kubectl apply -f deploy/kubernetes/base/services/
	@echo ""
	@echo "✓  Deployed. Check pod status:"
	@echo "     kubectl get pods -n finance"
	@echo "   Dashboard available at: http://localhost:30080"
	@echo "   (or: kubectl port-forward svc/frontend 3000:80 -n finance)"

## deploy-k8s-eks: Deploy to EKS using Kustomize overlay.
##                 Patches base manifests with ECR image URLs, gp3 StorageClass,
##                 and imagePullPolicy:Always. Safe to re-run (idempotent).
##                 Prerequisites: make tf-apply-aws, make tf-configure-kubectl, make build-ecr.
deploy-k8s-eks:
	bash scripts/generate-eks-kustomization.sh
	@echo "Creating finance namespace (idempotent)..."
	kubectl apply -f deploy/kubernetes/base/00-namespace.yaml
	@echo "Creating Keycloak realm ConfigMap..."
	kubectl create configmap keycloak-realm-import \
		--from-file=identity-provider/realm-export/ \
		-n finance --dry-run=client -o yaml | kubectl apply -f -
	@echo "Applying config and secrets..."
	kubectl apply -f deploy/kubernetes/base/01-config.yaml
	kubectl apply -f deploy/kubernetes/base/02-secrets.yaml
	@echo "Applying EKS overlay (ECR images + gp3 StorageClass + infrastructure + services)..."
	kubectl apply -k deploy/kubernetes/overlays/eks
	@echo "Waiting for PostgreSQL to be ready..."
	kubectl rollout status statefulset/postgres-ledger -n finance --timeout=120s
	@echo ""
	@echo "✓  Deployed. Check pod status:"
	@echo "     kubectl get pods -n finance"

## deploy-k8s-dd: Deploy the Datadog Agent. Auto-detects local (Colima/k3s) vs EKS.
##               Run AFTER 'make deploy-k8s' (local) or 'make deploy-k8s-eks' (EKS).
##
##               LOCAL: installs Operator (if absent), creates the datadog-secret from
##                      deploy/kubernetes/datadog/secrets/datadog-secrets.yaml (edit that
##                      file with your API key first), applies the base agent config.
##
##               EKS:   installs Operator via Helm (idempotent), fetches the API key
##                      automatically from AWS Secrets Manager, patches the agent config
##                      for Bottlerocket (log path, kubelet TLS, cloud tags).
deploy-k8s-dd:
	@echo "==> Detecting cluster environment..."
	@IS_EKS=$$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | grep -c 'aws:///') ; \
	IS_BOTTLEROCKET=$$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.osImage}' 2>/dev/null | grep -ic 'bottlerocket') ; \
	if [ "$$IS_EKS" -gt 0 ]; then \
		echo "    Detected: EKS$$([ $$IS_BOTTLEROCKET -gt 0 ] && echo ' + Bottlerocket' || echo '')"; \
		echo "==> Installing Datadog Operator via Helm (idempotent)..."; \
		helm repo add datadog https://helm.datadoghq.com 2>/dev/null || true; \
		helm repo update datadog 2>/dev/null; \
		helm upgrade --install datadog-operator datadog/datadog-operator \
			--namespace datadog --create-namespace \
			--set watchNamespaces="{datadog,finance}" \
			--wait --timeout 120s; \
		echo "==> Fetching DD_API_KEY from AWS Secrets Manager..."; \
		SECRET_ARN=$$(cd deploy/terraform/aws && terraform output -raw dd_api_key_secret_arn 2>/dev/null); \
		if [ -z "$$SECRET_ARN" ]; then \
			echo "ERROR: could not read dd_api_key_secret_arn from Terraform output."; \
			echo "       Run 'make tf-apply-aws' first."; \
			exit 1; \
		fi; \
		AWS_REGION=$$(grep '^aws_region' deploy/terraform/aws/staging.tfvars | sed 's/.*=[ ]*//' | tr -d '"' | tr -d ' '); \
		if [ -z "$$AWS_REGION" ]; then \
			echo "ERROR: aws_region not set in deploy/terraform/aws/staging.tfvars"; exit 1; \
		fi; \
		AWS_PROF=$$(grep '^aws_profile' deploy/terraform/aws/staging.tfvars | sed 's/.*=[ ]*//' | tr -d '"' | tr -d ' '); \
		PROFILE_FLAG=$$([ -n "$$AWS_PROF" ] && echo "--profile $$AWS_PROF" || echo ''); \
		DD_API_KEY=$$(aws secretsmanager get-secret-value \
			--secret-id $$SECRET_ARN \
			--region $$AWS_REGION $$PROFILE_FLAG \
			--query SecretString --output text 2>/dev/null); \
		if [ "$$DD_API_KEY" = "REPLACE_ME" ] || [ -z "$$DD_API_KEY" ]; then \
			echo "ERROR: DD_API_KEY in Secrets Manager is still the placeholder value."; \
			echo "       Run: aws secretsmanager put-secret-value \\"; \
			echo "              --secret-id $$SECRET_ARN --secret-string <your-dd-api-key>"; \
			echo "       Then re-run: make deploy-k8s-dd"; \
			exit 1; \
		fi; \
		kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f -; \
		kubectl create secret generic datadog-secret \
			--from-literal api-key="$$DD_API_KEY" \
			--namespace datadog \
			--dry-run=client -o yaml | kubectl apply -f -; \
		LOG_PATH=$$([ $$IS_BOTTLEROCKET -gt 0 ] && echo '/var/log/containers' || echo '/var/lib/docker/containers'); \
		echo "==> Applying EKS agent config (log path: $$LOG_PATH)..."; \
		sed "s|containerLogsPath:.*|containerLogsPath: $$LOG_PATH|" \
			deploy/kubernetes/overlays/eks-datadog/datadog-agent-eks-patch.yaml \
			| kubectl apply -f -; \
	else \
		echo "    Detected: local cluster"; \
		echo "==> Checking Datadog Operator is installed..."; \
		if ! kubectl get crd datadogagents.datadoghq.com >/dev/null 2>&1; then \
			echo "ERROR: Datadog Operator CRD not found."; \
			echo "       Install it first:"; \
			echo "         helm repo add datadog https://helm.datadoghq.com"; \
			echo "         helm install datadog-operator datadog/datadog-operator \\"; \
			echo "           --namespace datadog --create-namespace \\"; \
			echo "           --set watchNamespaces='{datadog,finance}'"; \
			exit 1; \
		fi; \
		echo "==> Applying local cluster config..."; \
		kubectl apply -f deploy/kubernetes/datadog/secrets/; \
		kubectl apply -f deploy/kubernetes/datadog/agent/; \
	fi
	@kubectl apply -f deploy/kubernetes/datadog/checks/
	@echo ""
	@echo "✓  Datadog Agent deploying. Verify with:"
	@echo "     kubectl get datadogagent -n datadog"
	@echo "     kubectl get daemonset datadog -n datadog"
	@echo "     kubectl get deployment datadog-cluster-agent -n datadog"

## undeploy-k8s: Remove all Finance app resources from Kubernetes.
undeploy-k8s:
	kubectl delete namespace finance --ignore-not-found
	# gp3 is cluster-scoped (not namespaced) — must be deleted separately
	kubectl delete storageclass gp3 --ignore-not-found

## tf-plan-aws: Initialise and plan the Terraform AWS (EKS) target.
##              Uses the AWS_PROFILE env var. Override vars: TF_AWS_VARS="-var-file=staging.tfvars -var aws_profile=<name>"
TF_AWS_VARS ?= -var-file=staging.tfvars
tf-plan-aws:
	cd deploy/terraform/aws && terraform init && terraform plan $(TF_AWS_VARS)

## tf-apply-aws: Apply the Terraform AWS plan (creates EKS, ECR, VPC, IAM).
##               WARNING: this provisions real AWS resources and incurs cost.
tf-apply-aws:
	bash scripts/aws-pre-apply.sh
	cd deploy/terraform/aws && terraform init && terraform apply $(TF_AWS_VARS)

## tf-configure-kubectl: Update kubeconfig to point kubectl at the EKS cluster.
##                       Run after tf-apply-aws before deploy-k8s.
tf-configure-kubectl:
	eval "$$(cd deploy/terraform/aws && terraform output -raw kubeconfig_command)"

## frontend-url: Print the public URL of the Finance app frontend on EKS.
##               Only works after make deploy-k8s-eks (requires LoadBalancer to be provisioned).
frontend-url:
	@kubectl get svc frontend -n finance \
		-o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}{"\n"}' 2>/dev/null \
		|| echo "No LoadBalancer yet — run 'make deploy-k8s-eks' first."

## tf-destroy-aws: Destroy all AWS resources created by Terraform.
##                 WARNING: this deletes the EKS cluster and all data.
##                 Use this for normal teardown when Terraform state is consistent.
##                 If it fails with ResourceInUseException or secrets stuck in
##                 deletion queue, use tf-force-destroy-aws instead.
tf-destroy-aws:
	cd deploy/terraform/aws && terraform destroy $(TF_AWS_VARS)

## tf-force-destroy-aws: Force-destroy in dependency order when tf-destroy-aws fails.
##                        Deletes EKS node groups + add-ons via AWS CLI first (required
##                        before the cluster can be deleted), force-deletes Secrets Manager
##                        secrets bypassing the 7-day recovery window, then runs
##                        terraform destroy for the remaining resources (VPC, IAM, KMS).
##                        Use when:
##                          - EKS returns ResourceInUseException: Cluster has nodegroups attached
##                          - Secrets Manager returns: secret is scheduled for deletion
##                          - Terraform state is partially applied after a failed run
tf-force-destroy-aws:
	bash scripts/aws-force-destroy.sh

## dd-secrets: Print eval-ready export commands for TF_VAR_datadog_api_key and
##             TF_VAR_datadog_app_key, sourced from AWS Secrets Manager.
##             Usage: eval "$(make dd-secrets)"
##             Requires: valid AWS SSO session (aws sso login --profile <profile>)
.PHONY: dd-secrets
dd-secrets:
	@AWS_REGION=$$(grep '^aws_region' deploy/terraform/aws/staging.tfvars 2>/dev/null | sed 's/.*=[ ]*//' | tr -d '"' | tr -d ' '); \
	if [ -z "$$AWS_REGION" ]; then AWS_REGION=eu-west-1; fi; \
	AWS_PROF=$$(grep '^aws_profile' deploy/terraform/aws/staging.tfvars 2>/dev/null | sed 's/.*=[ ]*//' | tr -d '"' | tr -d ' '); \
	PROFILE_FLAG=$$([ -n "$$AWS_PROF" ] && echo "--profile $$AWS_PROF" || echo ''); \
	API_KEY=$$(aws secretsmanager get-secret-value \
		--secret-id finance-app/staging/dd-api-key \
		--query SecretString --output text \
		--region $$AWS_REGION $$PROFILE_FLAG 2>/dev/null); \
	APP_KEY=$$(aws secretsmanager get-secret-value \
		--secret-id finance-app/staging/dd-app-key \
		--query SecretString --output text \
		--region $$AWS_REGION $$PROFILE_FLAG 2>/dev/null); \
	if [ -z "$$API_KEY" ] || [ -z "$$APP_KEY" ]; then \
		echo "# ERROR: could not fetch secrets from Secrets Manager (region=$$AWS_REGION profile=$$AWS_PROF)" >&2; \
		echo "# Make sure your AWS SSO session is valid: aws sso login --profile $$AWS_PROF" >&2; \
		exit 1; \
	fi; \
	echo "export TF_VAR_datadog_api_key=\"$$API_KEY\""; \
	echo "export TF_VAR_datadog_app_key=\"$$APP_KEY\""

## tf-plan-dd: Plan the Datadog observability resources (index, pipeline, monitors, dashboard).
##             Requires TF_VAR_datadog_api_key and TF_VAR_datadog_app_key env vars.
##             Easiest way to set them: eval "$(make dd-secrets)"
TF_DD_VARS ?= -var-file=staging.tfvars
tf-plan-dd:
	cd deploy/terraform/datadog && terraform init && terraform plan $(TF_DD_VARS)

## tf-apply-dd: Apply the Datadog resources (index, pipeline, monitors, dashboard).
##              WARNING: creates/updates live Datadog configuration.
tf-apply-dd:
	cd deploy/terraform/datadog && terraform init && terraform apply -auto-approve $(TF_DD_VARS)

## tf-destroy-dd: Destroy all Datadog resources created by this Terraform module.
##                WARNING: deletes the log index (and all indexed logs), monitors, and dashboard.
tf-destroy-dd:
	cd deploy/terraform/datadog && terraform destroy $(TF_DD_VARS)

# ── GCP targets (scaffolded but not yet tested — coming soon) ──────────────────
# Uncomment when GCP support is ready:
#
# TF_GCP_VARS ?= -var-file=staging.tfvars
#
# tf-plan-gcp:
# 	cd deploy/terraform/gcp && terraform init && terraform plan $(TF_GCP_VARS)
#
# tf-apply-gcp:
# 	cd deploy/terraform/gcp && terraform init && terraform apply $(TF_GCP_VARS)
#
# tf-configure-kubectl-gcp:
# 	eval "$$(cd deploy/terraform/gcp && terraform output -raw get_credentials_command)"
#
# tf-destroy-gcp:
# 	cd deploy/terraform/gcp && terraform destroy $(TF_GCP_VARS)
