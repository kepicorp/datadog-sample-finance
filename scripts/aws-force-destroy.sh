#!/usr/bin/env bash
# =============================================================================
# aws-force-destroy.sh — Destroy all finance-app AWS resources in the correct
# dependency order. Called by 'make tf-destroy-aws'.
#
# Usage:
#   aws sso login --profile partner
#   make tf-destroy-aws
#   # or directly:
#   bash scripts/aws-force-destroy.sh [profile] [region] [cluster_name] [environment]
#
# Defaults: profile=partner, region=eu-west-1, cluster=finance-app, env=staging
# =============================================================================
set -euo pipefail

# Suppress AWS CLI pager for all calls in this script.
export AWS_PAGER=""

PROFILE="${1:-partner}"
CLUSTER="${3:-finance-app}"
ENV="${4:-staging}"

# Region: prefer explicit arg ($2), then read from staging.tfvars.
if [ -n "${2:-}" ]; then
  REGION="$2"
elif [ -f "deploy/terraform/aws/staging.tfvars" ]; then
  REGION=$(grep '^aws_region' deploy/terraform/aws/staging.tfvars | sed 's/.*=[ ]*//' | tr -d '"' | tr -d ' ')
  if [ -z "$REGION" ]; then
    echo "ERROR: aws_region not found in deploy/terraform/aws/staging.tfvars."
    echo "       Pass it explicitly: bash scripts/aws-force-destroy.sh $PROFILE <region>"
    exit 1
  fi
else
  echo "ERROR: deploy/terraform/aws/staging.tfvars not found and no region passed as arg."
  echo "       Usage: bash scripts/aws-force-destroy.sh [profile] [region] [cluster] [env]"
  exit 1
fi

export AWS_PROFILE="$PROFILE"
export AWS_DEFAULT_REGION="$REGION"

# ── Confirmation prompt ───────────────────────────────────────────────────────
echo ""
echo "  ┌─────────────────────────────────────────────────────────────────┐"
echo "  │  WARNING: This will permanently delete all finance-app AWS      │"
echo "  │  resources: EKS cluster, VPC, ECR repos, IAM roles, secrets.   │"
echo "  │                                                                 │"
echo "  │  Profile : $PROFILE"
echo "  │  Region  : $REGION"
echo "  │  Cluster : $CLUSTER"
echo "  └─────────────────────────────────────────────────────────────────┘"
echo ""
read -r -p "  Type 'yes' to confirm: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 1
fi
echo ""

echo "==> Using profile=$PROFILE region=$REGION cluster=$CLUSTER env=$ENV"
echo ""

# ── 0. Delete Kubernetes LoadBalancer services (releases AWS ELBs) ───────────
# K8s services of type LoadBalancer provision an AWS ELB outside Terraform's
# state. If the ELB still exists when Terraform tries to delete the VPC/subnets,
# AWS returns DependencyViolation and the destroy fails.
# We delete the K8s namespace first (which triggers ELB deletion), then wait
# for the ELBs to fully de-register before proceeding.
echo "==> [0/7] Releasing AWS LoadBalancers via kubectl..."
if kubectl get namespace finance --request-timeout=5s >/dev/null 2>&1; then
  echo "    Deleting finance namespace (triggers ELB release)..."
  kubectl delete namespace finance --ignore-not-found --wait=true --timeout=120s 2>/dev/null || true
  kubectl delete storageclass gp3 --ignore-not-found 2>/dev/null || true
  echo "    Namespace deleted. Waiting 20s for ELB de-registration..."
  sleep 20
else
  echo "    kubectl not reachable or namespace already gone — skipping."
fi
echo ""

# ── 1. Delete EKS node groups (must go before the cluster) ───────────────────
echo "==> [1/7] Deleting EKS node groups..."
NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER" \
  --query 'nodegroups[]' --output text 2>/dev/null || true)

if [ -n "$NODEGROUPS" ]; then
  for NG in $NODEGROUPS; do
    echo "    Deleting node group: $NG"
    aws eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" \
      --query 'nodegroup.nodegroupName' --output text 2>/dev/null || true
  done
  echo "    Waiting for node groups to finish deleting (this takes ~3-5 min)..."
  for NG in $NODEGROUPS; do
    aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --nodegroup-name "$NG" 2>/dev/null || true
    echo "    Node group $NG deleted."
  done
else
  echo "    No node groups found."
fi

# ── 2. Delete EKS add-ons ─────────────────────────────────────────────────────
echo ""
echo "==> [2/7] Deleting EKS add-ons..."
ADDONS=$(aws eks list-addons --cluster-name "$CLUSTER" \
  --query 'addons[]' --output text 2>/dev/null || true)

if [ -n "$ADDONS" ]; then
  for ADDON in $ADDONS; do
    echo "    Deleting add-on: $ADDON"
    aws eks delete-addon --cluster-name "$CLUSTER" --addon-name "$ADDON" \
      --query 'addon.addonName' --output text 2>/dev/null || true
  done
else
  echo "    No add-ons found."
fi

# ── 3. Delete the EKS cluster ────────────────────────────────────────────────
echo ""
echo "==> [3/7] Deleting EKS cluster: $CLUSTER..."
if aws eks delete-cluster --name "$CLUSTER" --query 'cluster.name' --output text 2>/dev/null; then
  echo "    Waiting for cluster deletion..."
  aws eks wait cluster-deleted --name "$CLUSTER" 2>/dev/null && echo "    Cluster deleted." || true
else
  echo "    Cluster not found or already deleted."
fi

# ── 4. Force-delete Secrets Manager secrets ──────────────────────────────────
echo ""
echo "==> [4/7] Force-deleting Secrets Manager secrets..."
for SECRET in \
  "finance-app/${ENV}/dd-api-key" \
  "finance-app/${ENV}/dd-app-key" \
  "finance-app/${ENV}/datadog-dbm-password"; do
  echo "    Deleting secret: $SECRET"
  aws secretsmanager delete-secret \
    --secret-id "$SECRET" \
    --force-delete-without-recovery \
    --query 'Name' --output text 2>/dev/null && echo "    Deleted." || echo "    Not found or already deleted."
done

# ── 5. Delete ECR repositories ───────────────────────────────────────────────
echo ""
echo "==> [5/7] Deleting ECR repositories..."
for REPO in \
  finance-app/gateway-api finance-app/account-service finance-app/transaction-service \
  finance-app/fraud-detection finance-app/notification-service finance-app/batch-processor; do
  echo "    Deleting ECR repo: $REPO"
  aws ecr delete-repository --repository-name "$REPO" --force \
    --query 'repository.repositoryName' --output text 2>/dev/null && \
    echo "    Deleted." || echo "    Not found or already deleted."
done

# ── 6. CloudWatch log groups ──────────────────────────────────────────────────
# The /aws/eks/<cluster>/cluster log group is managed by Terraform and will be
# deleted in step 7 (terraform destroy). No manual action needed here.
echo ""
echo "==> [6/7] CloudWatch log group: handled by terraform destroy in step 7."

# ── 7. Run terraform destroy for remaining resources (VPC, IAM, KMS, SGs) ────
echo ""
echo "==> [7/7] Running terraform destroy for remaining resources (VPC, IAM, KMS)..."
cd "$(dirname "$0")/../deploy/terraform/aws"
terraform destroy -var-file="staging.tfvars" -auto-approve

echo ""
echo "✓  Destroy complete."
