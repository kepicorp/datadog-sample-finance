# Finance Sample App — Datadog Observability
#
# DD_VERSION is auto-set to the git short SHA for Deployment Tracking.
# This ties every container image to an exact commit so that anomalies
# surfaced in Datadog APM, Profiler, or Data Jobs Monitoring can be
# linked back to a specific release via the Deployment Tracking UI.
# Docs: https://docs.datadoghq.com/tracing/deployment_tracking/
#
# Run 'make help' for the full list of targets with one-line descriptions.
# The end-to-end workflows below show the recommended target ordering.
#
# AWS + K8s workflow:
#   aws sso login --profile <profile>   # authenticate
#   make tf-plan-aws                    # review the plan first
#   make tf-apply-aws                   # provision EKS, ECR, VPC, IAM (~15-20 min)
#   make tf-configure-kubectl           # configure kubectl
#   make build-ecr                      # build & push images for linux/amd64
#   make deploy-k8s-eks                 # deploy app (includes gp3 StorageClass)
#   make deploy-k8s-dd                  # deploy Datadog Agent (auto-detects EKS)

.PHONY: all build build-ecr version test test-traffic deploy-k8s deploy-k8s-eks deploy-k8s-dd undeploy-k8s teardown instrument uninstrument create-dd-secret tf-plan-aws tf-apply-aws tf-configure-kubectl frontend-url tf-destroy-aws dd-secrets tf-plan-dd tf-apply-dd tf-destroy-dd help

# Resolve DD_VERSION once so all targets share the same value.
# Falls back to 'dev' when git is not available (e.g. in a bare CI image).
DD_VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo 'dev')

# ── Reusable canned recipes ───────────────────────────────────────────
# Expanded inline inside recipes with $(macro_name). Each keeps its own
# backslash continuations so it slots into a single recipe shell.

# Install/upgrade the Datadog Operator via Helm (idempotent).
define install_dd_operator
	helm repo add datadog https://helm.datadoghq.com 2>/dev/null || true; \
	helm repo update datadog 2>/dev/null; \
	helm upgrade --install datadog-operator datadog/datadog-operator \
		--namespace datadog --create-namespace \
		--set watchNamespaces="{datadog,finance}" \
		--set maximumGoroutines=800 \
		--wait --timeout 120s
endef

# Create the keycloak-tls Secret (self-signed) unless it already exists.
define ensure_keycloak_tls
	if ! kubectl get secret keycloak-tls -n finance >/dev/null 2>&1; then \
		openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
			-keyout /tmp/keycloak-tls.key \
			-out /tmp/keycloak-tls.crt \
			-subj "/CN=localhost/O=finance-sample-app" \
			-addext "subjectAltName=DNS:localhost,DNS:keycloak,IP:127.0.0.1" \
			2>/dev/null; \
		kubectl create secret tls keycloak-tls \
			--cert=/tmp/keycloak-tls.crt \
			--key=/tmp/keycloak-tls.key \
			-n finance; \
		rm -f /tmp/keycloak-tls.crt /tmp/keycloak-tls.key; \
		echo "  ✓ keycloak-tls Secret created"; \
	else \
		echo "  keycloak-tls Secret already exists — skipping"; \
	fi
endef

# Create the keycloak-realm-import ConfigMap from the realm export dir.
define create_realm_cm
	kubectl create configmap keycloak-realm-import \
		--from-file=identity-provider/realm-export/ \
		-n finance --dry-run=client -o yaml | kubectl apply -f -
endef

# Create the traffic-generator-script ConfigMap.
define create_traffic_cm
	kubectl create configmap traffic-generator-script \
		--from-file=generate-traffic.py=scripts/generate-traffic.py \
		-n finance --dry-run=client -o yaml | kubectl apply -f -
endef

# Build the frontend-dashboard ConfigMap, injecting KEYCLOAK_PUBLIC_URL.
define create_frontend_cm
	KEYCLOAK_URL=$$(grep 'KEYCLOAK_PUBLIC_URL' deploy/kubernetes/base/01-config.yaml | sed 's/.*: *"\(.*\)"/\1/'); \
	sed "s|https://localhost:30443|$$KEYCLOAK_URL|g" frontend-stub/index.html > /tmp/finance-index.html; \
	kubectl create configmap frontend-dashboard \
		--from-file=index.html=/tmp/finance-index.html \
		-n finance --dry-run=client -o yaml | kubectl apply -f -; \
	rm -f /tmp/finance-index.html
endef

# Print the "redeploy to activate" hint shared by instrument/uninstrument.
define print_redeploy_hint
	echo "   Local: make build && load images into k3s && kubectl rollout restart deployment -n finance"; \
	echo "   EKS:   make build-ecr && make deploy-k8s-eks && kubectl rollout restart deployment -n finance"
endef
# ──────────────────────────────────────────────────────────────────────


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
##             Idempotent: a second run is a clean no-op (tracked via .instrumentation-applied).
##             See INSTRUMENTATION.md for what each patch enables.
##
##             RUM PREREQUISITE: run 'make tf-apply-dd' FIRST. The RUM applicationId
##               and clientToken are created by the Datadog Terraform module; this
##               target injects them into frontend-stub/index.html. Without them the
##               frontend RUM block keeps its placeholders (a ⚠ warning is printed) —
##               all other (backend) instrumentation still applies. Just re-run
##               'make instrument' after 'make tf-apply-dd' to fill in RUM.
##
##             After patching, redeploy:
##               Local:  make build && load images into k3s && kubectl rollout restart deployment -n finance
##               EKS:    make build-ecr && make deploy-k8s-eks && kubectl rollout restart deployment -n finance
instrument:
	@if [ -f .instrumentation-applied ]; then \
		echo "Instrumentation already enabled. Run 'make uninstrument' first to reapply."; \
	else \
		echo "Applying instrumentation patches..."; \
		for p in scripts/patches/*.patch; do \
			svc=$$(basename $$p .patch); \
			echo "  $$svc"; \
			patch -p1 --forward -s < $$p || true; \
		done; \
		touch .instrumentation-applied; \
		echo ""; \
		echo "==> Injecting RUM credentials from Terraform output..."; \
		TF_DD_DIR="$(CURDIR)/deploy/terraform/datadog"; \
		if terraform -chdir="$$TF_DD_DIR" output rum_application_id >/dev/null 2>&1; then \
			RUM_APP_ID=$$(terraform -chdir="$$TF_DD_DIR" output -raw rum_application_id 2>/dev/null); \
			RUM_TOKEN=$$(terraform -chdir="$$TF_DD_DIR" output -raw rum_client_token 2>/dev/null); \
			if [ -n "$$RUM_APP_ID" ] && [ -n "$$RUM_TOKEN" ]; then \
				sed -i '' \
					"s|'REPLACE_WITH_APPLICATION_ID'|'$$RUM_APP_ID'|g" \
					frontend-stub/index.html; \
				sed -i '' \
					"s|'REPLACE_WITH_CLIENT_TOKEN'|'$$RUM_TOKEN'|g" \
					frontend-stub/index.html; \
				echo "  ✓ RUM credentials injected (app_id: $$RUM_APP_ID)"; \
			else \
				echo "  ⚠  RUM output is empty — run 'make tf-apply-dd' first, then re-run 'make instrument'"; \
					fi; \
				else \
					echo "  ⚠  Terraform output not available — run 'make tf-apply-dd' first to create the RUM app."; \
					echo "     RUM block left with placeholders. Re-run 'make instrument' after 'make tf-apply-dd'."; \
				fi; \
				echo ""; \
				echo "✓ Instrumentation enabled. Redeploy to activate:"; \
				$(print_redeploy_hint); \
			fi

## uninstrument: Re-comment all Datadog instrumentation blocks (reverse of make instrument).
##               Restores every file to its original commented-out state.
##
##               After patching, redeploy:
##                 Local:  make build && load images into k3s && kubectl rollout restart deployment -n finance
##                 EKS:    make build-ecr && make deploy-k8s-eks && kubectl rollout restart deployment -n finance
uninstrument:
	@if [ ! -f .instrumentation-applied ]; then \
		echo "Instrumentation is not currently enabled (nothing to reverse)."; \
	else \
		echo "Reversing instrumentation patches..."; \
		for p in scripts/patches/*.patch; do \
			svc=$$(basename $$p .patch); \
			echo "  $$svc"; \
			patch -p1 --reverse -s < $$p || true; \
		done; \
		rm -f .instrumentation-applied; \
		echo "==> Restoring RUM credential placeholders..."; \
		sed -i '' \
			"s|'[a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}'|'REPLACE_WITH_APPLICATION_ID'|g" \
			frontend-stub/index.html; \
		sed -i '' \
			"s|clientToken:             '[a-z0-9]*'|clientToken:             'REPLACE_WITH_CLIENT_TOKEN'|g" \
			frontend-stub/index.html; \
		echo "  ✓ RUM placeholders restored"; \
		echo ""; \
		echo "✓ Instrumentation disabled. Redeploy to deactivate:"; \
		$(print_redeploy_hint); \
	fi

## build: Build all service images for the local platform.
##        Images are tagged finance-sample-app-<service>:latest and :<DD_VERSION> (git short SHA).
##        Docker Desktop / Rancher Desktop: images are available in the cluster immediately.
##        Other tools — load after building:
##          kind:     kind load docker-image finance-sample-app-<svc>:latest
##          k3d:      k3d image import finance-sample-app-<svc>:latest
##          minikube: minikube image load finance-sample-app-<svc>:latest
##        Then rolling-restart to pick up new images:
##          kubectl rollout restart deployment -n finance
build:
	@echo "Building all service images (DD_VERSION=$(DD_VERSION))..."
	@for svc in gateway-api account-service transaction-service fraud-detection notification-service batch-processor; do \
		echo "  → $$svc"; \
		docker build -t finance-sample-app-$$svc:latest \
		             -t finance-sample-app-$$svc:$(DD_VERSION) \
		             --build-arg DD_VERSION=$(DD_VERSION) \
		             ./$$svc; \
	done
	@echo ""
	@echo "✓ All images built. To deploy to local k3s:"
	@echo "  # Docker Desktop/Rancher Desktop: images available immediately — no load step needed."
	@echo "  # kind:     kind load docker-image finance-sample-app-<svc>:latest"
	@echo "  # k3d:      k3d image import finance-sample-app-<svc>:latest"
	@echo "  # minikube: minikube image load finance-sample-app-<svc>:latest"
	@echo "  kubectl rollout restart deployment -n finance"

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

## test: Run the e2e test suite against the running stack.
##       Prerequisites: make deploy-k8s (uses Python stdlib only — no pip install required).
##       Note: requires kubectl port-forward or NodePort access to the services.
##       For a no-setup check, watch the in-cluster traffic generator instead:
##         kubectl logs -n finance deploy/traffic-generator -f
test:
	python3 scripts/test-e2e.py

## test-traffic: Run the traffic generator locally for a fixed duration.
##               The in-cluster traffic-generator Deployment already runs continuously.
##               Use this to temporarily boost traffic or test from your laptop.
##               Note: requires services reachable on localhost (kubectl port-forward).
test-traffic:
	python3 scripts/generate-traffic.py --rate 2 --duration 60



## deploy-k8s: Deploy the Finance app to Kubernetes without Datadog.
##             Creates the 'finance' namespace and all infrastructure + application services.
##             Prerequisites:
##               1. make build        — build all service images
##               2. kubectl configured — pointing at your target cluster
##             On Docker Desktop / Rancher Desktop, images built by
##             'make build' are immediately available (imagePullPolicy: IfNotPresent).
##             On kind/k3d/minikube, load images after building (see 'make build' help).
deploy-k8s:
	@echo "Creating finance namespace (idempotent)..."
	kubectl apply -f deploy/kubernetes/base/00-namespace.yaml
	@echo "Creating Keycloak realm ConfigMap..."
	@$(create_realm_cm)
	@echo "Creating TLS secret for nginx Keycloak HTTPS proxy..."
	@$(ensure_keycloak_tls)
	@echo "Applying config, secrets and infrastructure..."
	kubectl apply -f deploy/kubernetes/base/01-config.yaml
	kubectl apply -f deploy/kubernetes/base/02-secrets.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/activemq-broker-config.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/activemq.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/keycloak.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/postgres-init.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/postgres.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/redis.yaml
	@echo "Waiting for PostgreSQL to be ready..."
	kubectl rollout status statefulset/postgres-ledger -n finance --timeout=120s
	@echo "Creating traffic-generator script ConfigMap..."
	@$(create_traffic_cm)
	@echo "Creating frontend dashboard ConfigMap (injecting KEYCLOAK_PUBLIC_URL)..."
	@$(create_frontend_cm)
	@echo "Applying application services (pinning DD version=$(DD_VERSION))..."
	@for f in account-service batch-processor fraud-detection frontend gateway-api notification-service transaction-service traffic-generator; do \
		echo "  → $$f"; \
		DD_VERSION=$(DD_VERSION) bash scripts/pin-dd-version.sh \
			< deploy/kubernetes/base/services/$$f.yaml | kubectl apply -f -; \
	done
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
	@$(create_realm_cm)
	@echo "Applying config and secrets..."
	kubectl apply -f deploy/kubernetes/base/01-config.yaml
	kubectl apply -f deploy/kubernetes/base/02-secrets.yaml
	@echo "Creating traffic-generator script ConfigMap..."
	@$(create_traffic_cm)
	@echo "Creating TLS secret for nginx Keycloak HTTPS proxy (idempotent)..."
	@$(ensure_keycloak_tls)
	@echo "Creating frontend dashboard ConfigMap (injecting current KEYCLOAK_PUBLIC_URL)..."
	@$(create_frontend_cm)
	@echo "Applying EKS overlay (ECR images + gp3 StorageClass + infrastructure + services; pinning DD version=$(DD_VERSION))..."
	kubectl kustomize deploy/kubernetes/overlays/eks \
		| DD_VERSION=$(DD_VERSION) bash scripts/pin-dd-version.sh \
		| kubectl apply -f -
	@echo "Waiting for PostgreSQL to be ready..."
	kubectl rollout status statefulset/postgres-ledger -n finance --timeout=120s
	@echo ""
	@echo "✓  Deployed. Check pod status:"
	@echo "     kubectl get pods -n finance"
	@echo ""
	@echo "⚠  Keycloak public URL: the frontend Service (nginx) sits behind the"
	@echo "   Terraform-managed NLB and proxies Keycloak — the keycloak Service"
	@echo "   itself is ClusterIP-only. The NLB hostname is already known (it was"
	@echo "   created by 'make tf-apply-aws', not by this Service), so run:"
	@echo "     FE_URL=\$$(cd deploy/terraform/aws && terraform output -raw frontend_url)"
	@echo "     kubectl patch configmap app-config -n finance --type=merge -p \"{\\\"data\\\":{\\\"KEYCLOAK_PUBLIC_URL\\\":\\\"\$$FE_URL\\\"}}\""
	@echo "     sed \"s|https://localhost:30443|\$$FE_URL|g\" frontend-stub/index.html > /tmp/finance-index.html"
	@echo "     kubectl create configmap frontend-dashboard --from-file=index.html=/tmp/finance-index.html -n finance --dry-run=client -o yaml | kubectl apply -f -"
	@echo "     kubectl rollout restart deployment/keycloak deployment/frontend -n finance"

## deploy-k8s-dd: Deploy the Datadog Agent. Auto-detects local vs EKS.
##               Run AFTER 'make deploy-k8s' (local) or 'make deploy-k8s-eks' (EKS).
##               'create-dd-secret' runs first as a prerequisite — no separate secret
##               step needed. Keeping it a prerequisite (rather than a $(MAKE) call
##               inside the recipe) means 'make -n deploy-k8s-dd' is a true dry-run.
##
##               LOCAL: reads DD_API_KEY + DD_APP_KEY from .env (via create-dd-secret),
##                      installs Operator (if absent), applies the Agent config.
##
##               EKS:   fetches keys from AWS Secrets Manager (via create-dd-secret,
##                      requires valid SSO session + staging.tfvars), installs Operator
##                      via Helm, applies the Bottlerocket-patched Agent overlay.
deploy-k8s-dd: create-dd-secret
	@echo "==> Detecting cluster environment..."
	@IS_EKS=$$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | grep -c 'aws:///') ; \
	IS_BOTTLEROCKET=$$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.osImage}' 2>/dev/null | grep -ic 'bottlerocket') ; \
	if [ "$$IS_EKS" -gt 0 ]; then \
		echo "    Detected: EKS$$([ $$IS_BOTTLEROCKET -gt 0 ] && echo ' + Bottlerocket' || echo '')"; \
		echo "==> Installing Datadog Operator via Helm (idempotent)..."; \
		$(install_dd_operator); \
		echo "==> Applying EKS agent config (Kustomize overlay — inherits full base spec)..."; \
		kubectl apply -k deploy/kubernetes/overlays/eks-datadog; \
	else \
		echo "    Detected: local cluster"; \
		echo "==> Checking Datadog Operator is installed and running..."; \
		if ! kubectl get crd datadogagents.datadoghq.com >/dev/null 2>&1; then \
			echo "    CRD not found — installing Datadog Operator via Helm..."; \
			$(install_dd_operator); \
		elif ! kubectl get deployment datadog-operator -n datadog >/dev/null 2>&1 || \
			[ "$$(kubectl get deployment datadog-operator -n datadog -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" != "1" ]; then \
			echo "    CRD exists but Operator Deployment is missing or not available"; \
			echo "    (this happens after 'make teardown', which removes the Helm release"; \
			echo "     but not the cluster-scoped CRD) — (re)installing via Helm..."; \
			$(install_dd_operator); \
		else \
			echo "    Datadog Operator already installed and running — skipping"; \
		fi; \
		echo "==> Applying local cluster config (Kustomize base)..."; \
		kubectl apply -k deploy/kubernetes/datadog/agent; \
	fi
	@kubectl apply -f deploy/kubernetes/datadog/checks/activemq-check.yaml
	@kubectl apply -f deploy/kubernetes/datadog/checks/postgres-check.yaml
	@echo ""
	@echo "✓  Datadog Agent deploying. Verify with:"
	@echo "     kubectl get datadogagent -n datadog"
	@echo "     kubectl get daemonset datadog -n datadog"
	@echo "     kubectl get deployment datadog-cluster-agent -n datadog"

## undeploy-k8s: Remove all Finance app resources from Kubernetes (namespaces only).
##               Does NOT delete persistent data — use 'make teardown' for a full reset.
undeploy-k8s:
	kubectl delete namespace finance --ignore-not-found
	kubectl delete namespace datadog --ignore-not-found
	# gp3 is cluster-scoped (not namespaced) — must be deleted separately
	kubectl delete storageclass gp3 --ignore-not-found

## teardown: Full reset — removes all K8s resources AND cleans up persistent data.
##           Deletes:
##             - finance namespace (all app pods, services, configmaps)
##             - datadog namespace (Agent, Operator, Cluster Agent)
##             - Datadog Operator Helm release
##             - Any leftover Docker volumes (postgres, redis, artemis, keycloak)
##             - Port-forward processes
##           Safe to run even if some resources are already gone.
##
##           After teardown, start fresh with:
##             make build && make deploy-k8s && make create-dd-secret && make deploy-k8s-dd
teardown:
	@echo "==> Killing any stray kubectl port-forward processes..."
	@pkill -f 'kubectl port-forward' 2>/dev/null || true
	@echo "==> Removing Datadog Agent CRD instance..."
	@kubectl delete datadogagent datadog -n datadog --ignore-not-found 2>&1 || true
	@echo "==> Deleting finance namespace (app pods, PVCs, services)..."
	@kubectl delete namespace finance --ignore-not-found 2>&1
	@echo "==> Deleting datadog namespace (Agent DaemonSet, Cluster Agent)..."
	@kubectl delete namespace datadog --ignore-not-found 2>&1
	@echo "==> Uninstalling Datadog Operator Helm release..."
	@helm uninstall datadog-operator -n datadog 2>/dev/null || true
	@echo "==> Removing leftover Docker volumes..."
	@for vol in postgres-data redis-data artemis-data keycloak-data datadog-run; do \
		docker volume rm finance-sample-app_$$vol 2>/dev/null && echo "  removed finance-sample-app_$$vol" || true; \
	done
	@# gp3 is cluster-scoped (EKS only) — safe to ignore if not present
	@kubectl delete storageclass gp3 --ignore-not-found 2>/dev/null || true
	@echo ""
	@echo "✓  Teardown complete. Cluster and data are clean."
	@echo "   Start fresh: make build && make deploy-k8s && make create-dd-secret && make deploy-k8s-dd"

## deploy/terraform/aws/staging.tfvars: auto-created from staging.tfvars.example
##                                       on first use (self-heals a missing file
##                                       instead of failing 'terraform plan/apply'
##                                       with a raw "Failed to read variables file").
deploy/terraform/aws/staging.tfvars:
	@cp deploy/terraform/aws/staging.tfvars.example $@
	@echo "==> Created $@ from staging.tfvars.example"
	@echo "    Edit it with your aws_profile / aws_region / cluster_name, then re-run."

## tf-plan-aws: Initialise and plan the Terraform AWS (EKS) target.
##              Uses the AWS_PROFILE env var. Override vars: TF_AWS_VARS="-var-file=staging.tfvars -var aws_profile=<name>"
TF_AWS_VARS ?= -var-file=staging.tfvars
tf-plan-aws: deploy/terraform/aws/staging.tfvars
	cd deploy/terraform/aws && terraform init && terraform plan $(TF_AWS_VARS)

## tf-apply-aws: Apply the Terraform AWS plan (creates EKS, ECR, VPC, IAM).
##               WARNING: this provisions real AWS resources and incurs cost.
tf-apply-aws: deploy/terraform/aws/staging.tfvars
	bash scripts/aws-pre-apply.sh
	cd deploy/terraform/aws && terraform init && terraform apply $(TF_AWS_VARS)

## tf-configure-kubectl: Update kubeconfig to point kubectl at the EKS cluster.
##                       Run after tf-apply-aws before deploy-k8s.
tf-configure-kubectl:
	eval "$$(cd deploy/terraform/aws && terraform output -raw kubeconfig_command)"

## frontend-url: Print the public URL of the Finance app frontend on EKS.
##               Available as soon as make tf-apply-aws completes (Terraform-managed
##               NLB, not a Kubernetes LoadBalancer Service) — no need to deploy the
##               app first.
frontend-url:
	@cd deploy/terraform/aws && terraform output -raw frontend_url 2>/dev/null && echo "" \
		|| echo "No NLB yet — run 'make tf-apply-aws' first."

## tf-destroy-aws: Safely destroy all AWS resources created by Terraform.
##                 Automatically handles the dependency ordering that plain
##                 'terraform destroy' gets wrong:
##                   1. Deletes K8s LoadBalancer services (releases the AWS ELB
##                      so the VPC can be deleted — skipped if kubectl unreachable)
##                   2. Deletes EKS node groups + add-ons via AWS CLI before the
##                      cluster (avoids ResourceInUseException)
##                   3. Force-deletes Secrets Manager secrets immediately
##                      (avoids 'scheduled for deletion' errors on re-apply)
##                   4. Runs terraform destroy for remaining resources (VPC, IAM)
tf-destroy-aws:
	bash scripts/aws-force-destroy.sh --yes



## create-dd-secret: Create (or update) the datadog-secret K8s Secret in the datadog namespace.
##                   AUTO-DETECTS the environment:
##                     Local (Docker Desktop / kind / k3d / minikube): reads DD_API_KEY and DD_APP_KEY from .env
##                     EKS:               fetches both keys from AWS Secrets Manager
##                   Safe to re-run — uses --dry-run=client | kubectl apply (idempotent).
##                   Run this BEFORE make deploy-k8s-dd.
create-dd-secret:
	@echo "==> Detecting cluster environment..."
	@IS_EKS=$$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | grep -c 'aws:///'); \
	kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null; \
	if [ "$$IS_EKS" -gt 0 ]; then \
		echo "    Detected: EKS — fetching keys from AWS Secrets Manager..."; \
		AWS_REGION=$$(grep '^aws_region' deploy/terraform/aws/staging.tfvars 2>/dev/null | sed 's/.*=[ ]*//' | tr -d '"' | tr -d ' '); \
		if [ -z "$$AWS_REGION" ]; then AWS_REGION=eu-west-1; fi; \
		AWS_PROF=$$(grep '^aws_profile' deploy/terraform/aws/staging.tfvars 2>/dev/null | sed 's/.*=[ ]*//' | tr -d '"' | tr -d ' '); \
		PROFILE_FLAG=$$([ -n "$$AWS_PROF" ] && echo "--profile $$AWS_PROF" || echo ''); \
		DD_API_KEY=$$(aws secretsmanager get-secret-value \
			--secret-id finance-app/staging/dd-api-key \
			--query SecretString --output text \
			--region $$AWS_REGION $$PROFILE_FLAG 2>/dev/null); \
		DD_APP_KEY=$$(aws secretsmanager get-secret-value \
			--secret-id finance-app/staging/dd-app-key \
			--query SecretString --output text \
			--region $$AWS_REGION $$PROFILE_FLAG 2>/dev/null); \
		DBM_PASSWORD=$$(aws secretsmanager get-secret-value \
			--secret-id finance-app/staging/dbm-password \
			--query SecretString --output text \
			--region $$AWS_REGION $$PROFILE_FLAG 2>/dev/null || echo ''); \
		if [ -z "$$DD_API_KEY" ] || [ "$$DD_API_KEY" = "REPLACE_ME" ]; then \
			echo "ERROR: DD_API_KEY not found in Secrets Manager (finance-app/staging/dd-api-key)."; \
			echo "       aws sso login --profile $$AWS_PROF  then re-run."; \
			exit 1; \
		fi; \
		if [ -z "$$DD_APP_KEY" ] || [ "$$DD_APP_KEY" = "REPLACE_ME" ]; then \
			echo "ERROR: DD_APP_KEY not found in Secrets Manager (finance-app/staging/dd-app-key)."; \
			exit 1; \
		fi; \
	else \
		echo "    Detected: local cluster — reading keys from .env..."; \
		ENV_FILE=.env; \
		if [ ! -f "$$ENV_FILE" ]; then \
			echo "ERROR: $$ENV_FILE not found."; \
			echo "       Copy .env.example to .env and fill in DD_API_KEY and DD_APP_KEY."; \
			exit 1; \
		fi; \
		DD_API_KEY=$$(grep '^DD_API_KEY' $$ENV_FILE | cut -d= -f2 | tr -d '"' | tr -d "'"); \
		DD_APP_KEY=$$(grep '^DD_APP_KEY' $$ENV_FILE | cut -d= -f2 | tr -d '"' | tr -d "'"); \
		DBM_PASSWORD=$$(grep '^DATADOG_DBM_PASSWORD' $$ENV_FILE | cut -d= -f2 | tr -d '"' | tr -d "'" || echo ''); \
		if [ -z "$$DD_API_KEY" ]; then \
			echo "ERROR: DD_API_KEY not set in $$ENV_FILE."; exit 1; \
		fi; \
		if [ -z "$$DD_APP_KEY" ]; then \
			echo "ERROR: DD_APP_KEY not set in $$ENV_FILE."; exit 1; \
		fi; \
	fi; \
	DBM_FLAG=$$([ -n "$$DBM_PASSWORD" ] && echo "--from-literal dbm-password=$$DBM_PASSWORD" || echo ''); \
	kubectl create secret generic datadog-secret \
		--from-literal api-key="$$DD_API_KEY" \
		--from-literal app-key="$$DD_APP_KEY" \
		$$DBM_FLAG \
		--namespace datadog \
		--dry-run=client -o yaml | kubectl apply -f -; \
	echo ""; \
	echo "✓  datadog-secret created/updated in namespace datadog"; \
	echo "   Keys stored: api-key, app-key$$([ -n "$$DBM_PASSWORD" ] && echo ', dbm-password' || echo ' (dbm-password not set)')"; \
	echo "   Verify: kubectl get secret datadog-secret -n datadog -o jsonpath='{.data}' | python3 -m json.tool"

## dd-secrets: Print eval-ready 'export TF_VAR_datadog_api_key=...' commands for use with
##             tf-apply-dd / tf-plan-dd. Resolves the keys in priority order:
##               1. AWS Secrets Manager  — if an SSO session for aws_profile is active
##                                          AND the finance-app/staging secrets exist
##               2. .env                 — DD_API_KEY / DD_APP_KEY (local fallback)
##             The .env fallback also kicks in when an AWS session is active but the
##             secrets aren't in Secrets Manager (the common local case), so this
##             works locally without needing to 'aws sso logout' first.
##             Usage: eval "$(make dd-secrets)"
dd-secrets:
	@AWS_PROF=$$(grep '^aws_profile' deploy/terraform/aws/staging.tfvars 2>/dev/null | sed 's/.*=[ ]*//' | tr -d '"' | tr -d ' '); \
	API_KEY=""; APP_KEY=""; SRC=""; \
	if [ -n "$$AWS_PROF" ] && aws sts get-caller-identity --profile "$$AWS_PROF" >/dev/null 2>&1; then \
		AWS_REGION=$$(grep '^aws_region' deploy/terraform/aws/staging.tfvars 2>/dev/null | sed 's/.*=[ ]*//' | tr -d '"' | tr -d ' '); \
		if [ -z "$$AWS_REGION" ]; then AWS_REGION=eu-west-1; fi; \
		API_KEY=$$(aws secretsmanager get-secret-value \
			--secret-id finance-app/staging/dd-api-key \
			--query SecretString --output text \
			--region $$AWS_REGION --profile "$$AWS_PROF" 2>/dev/null); \
		APP_KEY=$$(aws secretsmanager get-secret-value \
			--secret-id finance-app/staging/dd-app-key \
			--query SecretString --output text \
			--region $$AWS_REGION --profile "$$AWS_PROF" 2>/dev/null); \
		if [ -n "$$API_KEY" ] && [ -n "$$APP_KEY" ]; then \
			SRC="AWS Secrets Manager (profile $$AWS_PROF, region $$AWS_REGION)"; \
		else \
			echo "# dd-secrets: AWS session active but finance-app/staging secrets not found -- falling back to .env" >&2; \
			API_KEY=""; APP_KEY=""; \
		fi; \
	fi; \
	if { [ -z "$$API_KEY" ] || [ -z "$$APP_KEY" ]; } && [ -f .env ]; then \
		API_KEY=$$(grep '^DD_API_KEY=' .env | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"); \
		APP_KEY=$$(grep '^DD_APP_KEY=' .env | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"); \
		if [ -n "$$API_KEY" ] && [ -n "$$APP_KEY" ]; then SRC=".env"; fi; \
	fi; \
	if [ -z "$$API_KEY" ] || [ -z "$$APP_KEY" ]; then \
		echo "# ERROR: could not resolve Datadog keys." >&2; \
		echo "#   Local: cp .env.example .env && set DD_API_KEY / DD_APP_KEY" >&2; \
		echo "#   EKS:   aws sso login --profile $$AWS_PROF  (and ensure finance-app/staging/dd-*-key secrets exist)" >&2; \
		exit 1; \
	fi; \
	echo "# dd-secrets: sourced Datadog keys from $$SRC" >&2; \
	echo "export TF_VAR_datadog_api_key=\"$$API_KEY\""; \
	echo "export TF_VAR_datadog_app_key=\"$$APP_KEY\""

## tf-plan-dd: Plan the Datadog observability resources (index, pipeline, monitors, dashboard).
##             Requires TF_VAR_datadog_api_key and TF_VAR_datadog_app_key env vars.
##             Easiest way to set them: eval "$(make dd-secrets)"
TF_DD_VARS ?= -var-file=staging.tfvars
## deploy/terraform/datadog/staging.tfvars: auto-created from staging.tfvars.example
##                                           on first use -- self-heals a missing
##                                           file instead of failing with a raw
##                                           "Failed to read variables file" error.
deploy/terraform/datadog/staging.tfvars:
	@cp deploy/terraform/datadog/staging.tfvars.example $@
	@echo "==> Created $@ from staging.tfvars.example"
	@echo "    Edit it with your datadog_site / cluster_name / synthetic_target_base_url, then re-run."

tf-plan-dd: deploy/terraform/datadog/staging.tfvars
	cd deploy/terraform/datadog && terraform init && terraform plan $(TF_DD_VARS)

## tf-apply-dd: Apply the Datadog resources (index, pipeline, monitors, dashboard).
##              WARNING: creates/updates live Datadog configuration.
tf-apply-dd: deploy/terraform/datadog/staging.tfvars
	cd deploy/terraform/datadog && terraform init && terraform apply -auto-approve $(TF_DD_VARS)

## tf-destroy-dd: Destroy all Datadog resources created by this Terraform module.
##                WARNING: deletes the log index (and all indexed logs), monitors, dashboard, SLOs.
tf-destroy-dd: deploy/terraform/datadog/staging.tfvars
	cd deploy/terraform/datadog && terraform init && terraform destroy -auto-approve $(TF_DD_VARS)
