#!/usr/bin/env bash
# =============================================================================
# aws-force-destroy.sh — Force-delete the finance-app AWS resources in the
# correct dependency order when 'terraform destroy' fails due to partial state.
#
# Usage:
#   aws sso login --profile partner
#   bash scripts/aws-force-destroy.sh [profile] [region] [cluster_name] [environment]
#
# Defaults: profile=partner, region=eu-west-1, cluster=finance-app, env=staging
# =============================================================================
set -euo pipefail

PROFILE="${1:-partner}"
CLUSTER="${3:-finance-app}"
ENV="${4:-staging}"

# Region: prefer explicit arg ($2), then read from staging.tfvars.
# No hardcoded default — passing the wrong region would delete resources
# in the wrong account silently, which is worse than failing fast.
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

echo "==> Using profile=$PROFILE region=$REGION cluster=$CLUSTER env=$ENV"
echo ""

# ── 1. Delete EKS node groups (must go before the cluster) ───────────────────
echo "==> [1/7] Deleting EKS node groups..."
NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER" \
  --query 'nodegroups[]' --output text 2>/dev/null || true)

if [ -n "$NODEGROUPS" ]; then
  for NG in $NODEGROUPS; do
    echo "    Deleting node group: $NG"
    aws eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" || true
  done
  echo "    Waiting for node groups to finish deleting..."
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
    aws eks delete-addon --cluster-name "$CLUSTER" --addon-name "$ADDON" || true
  done
else
  echo "    No add-ons found."
fi

# ── 3. Delete the EKS cluster ────────────────────────────────────────────────
echo ""
echo "==> [3/7] Deleting EKS cluster: $CLUSTER..."
aws eks delete-cluster --name "$CLUSTER" 2>/dev/null && \
  echo "    Waiting for cluster deletion..." && \
  aws eks wait cluster-deleted --name "$CLUSTER" 2>/dev/null && \
  echo "    Cluster deleted." || \
  echo "    Cluster not found or already deleted."

# ── 4. Force-delete Secrets Manager secrets ──────────────────────────────────
echo ""
echo "==> [4/7] Force-deleting Secrets Manager secrets..."
for SECRET in \
  "finance-app/${ENV}/dd-api-key" \
  "finance-app/${ENV}/datadog-dbm-password"; do
  echo "    Deleting secret: $SECRET"
  aws secretsmanager delete-secret \
    --secret-id "$SECRET" \
    --force-delete-without-recovery 2>/dev/null && \
    echo "    Deleted." || \
    echo "    Not found or already deleted."
done

# ── 5. Delete ECR repositories ───────────────────────────────────────────────
echo ""
echo "==> [5/7] Deleting ECR repositories..."
for REPO in \
  finance-app/gateway-api finance-app/account-service finance-app/transaction-service \
  finance-app/fraud-detection finance-app/notification-service finance-app/batch-processor; do
  echo "    Deleting ECR repo: $REPO"
  aws ecr delete-repository --repository-name "$REPO" --force 2>/dev/null && \
    echo "    Deleted." || \
    echo "    Not found or already deleted."
done

# ── 6. CloudWatch log groups ──────────────────────────────────────────────────
echo ""
echo "==> [6/7] CloudWatch log groups are managed by Terraform — handled in step 7."
echo "    The EKS cluster log group orphan case is handled by scripts/aws-pre-apply.sh."

# ── 7. Run terraform destroy for remaining resources (VPC, IAM, KMS, SGs) ────
echo ""
echo "==> [7/7] Running terraform destroy for remaining resources (VPC, IAM, KMS)..."
echo "    This handles resources Terraform still tracks in state."
cd "$(dirname "$0")/../deploy/terraform/aws"
terraform destroy -var-file="staging.tfvars" -auto-approve

echo ""
echo "✓  Force-destroy complete."
