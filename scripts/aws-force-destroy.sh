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

# Parse --yes / -y flag (skip confirmation prompt) before positional args.
AUTO_YES=false
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --yes|-y) AUTO_YES=true ;;
    *) ARGS+=("$arg") ;;
  esac
done
set -- "${ARGS[@]+${ARGS[@]}}"

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
echo "  │  Profile : $PROFILE                                            │"
echo "  │  Region  : $REGION                                             │"
echo "  │  Cluster : $CLUSTER                                            │"
echo "  └─────────────────────────────────────────────────────────────────┘"
echo ""
if [ "$AUTO_YES" = true ]; then
  echo "  (auto-confirmed via --yes flag)"
else
  # Read directly from /dev/tty so the prompt works even when stdin is piped.
  read -r -p "  Type 'yes' to confirm: " CONFIRM </dev/tty
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi
fi
echo ""

echo "==> Using profile=$PROFILE region=$REGION cluster=$CLUSTER env=$ENV"
echo ""

# ── 0. Delete Kubernetes LoadBalancer services (releases AWS ELBs) ───────────
# ── 0. Release AWS ELBs and lingering ENIs from the VPC ───────────────────────────────────────────
# K8s LoadBalancer services create AWS ELBs outside Terraform's state.
# Terraform cannot delete the VPC/subnets while those ELBs or their lingering
# ENIs still exist (DependencyViolation). We:
#   a) Ask K8s to delete the namespace (triggers ELB deletion by the cloud controller)
#   b) Directly delete any ELBs tagged for this cluster via the AWS CLI
#   c) Wait for ELB-managed ENIs to fully detach before continuing
echo "==> [0/7] Releasing AWS ELBs and ENIs..."

# a) Try kubectl first (best-effort — may not be reachable if cluster already gone)
if kubectl get namespace finance --request-timeout=5s >/dev/null 2>&1; then
  echo "    Deleting finance namespace via kubectl (triggers ELB release)..."
  kubectl delete namespace finance --ignore-not-found --wait=true --timeout=120s 2>/dev/null || true
  kubectl delete storageclass gp3 --ignore-not-found 2>/dev/null || true
  echo "    Namespace deleted."
else
  echo "    kubectl not reachable — will clean up ELBs directly via AWS CLI."
fi

# b) Find and delete Classic ELBs in this VPC (K8s names them with a hash, not
#    the cluster name, so we must query by VPC rather than by name).
echo "    Checking for Classic ELBs in VPC..."
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "    Found VPC: $VPC_ID"
  CLASSIC_ELBS=$(aws elb describe-load-balancers \
    --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" \
    --output text 2>/dev/null || true)
  if [ -n "$CLASSIC_ELBS" ]; then
    for ELB in $CLASSIC_ELBS; do
      echo "    Deleting Classic ELB: $ELB"
      aws elb delete-load-balancer --load-balancer-name "$ELB" >/dev/null 2>&1 || true
    done
  else
    echo "    No Classic ELBs found in VPC."
  fi

  # b2) ALBs/NLBs in this VPC
  echo "    Checking for ALB/NLB load balancers in VPC..."
  V2_ELBS=$(aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" \
    --output text 2>/dev/null || true)
  if [ -n "$V2_ELBS" ]; then
    for ARN in $V2_ELBS; do
      echo "    Deleting ALB/NLB: $ARN"
      aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" >/dev/null 2>&1 || true
    done
  else
    echo "    No ALB/NLB found in VPC."
  fi
else
  echo "    VPC not found or already deleted — skipping ELB lookup."
fi

# c) Wait for ELB-managed ENIs to fully detach (status goes from 'in-use' to gone)
# These ENIs have description 'ELB ...' or 'Amazon EKS ...'
echo "    Waiting for ELB/ENIs to fully release (max 120s)..."
for i in $(seq 1 24); do
  ENI_COUNT=$(aws ec2 describe-network-interfaces \
    --filters \
      "Name=description,Values=ELB*" \
      "Name=status,Values=in-use" \
    --query 'length(NetworkInterfaces)' \
    --output text 2>/dev/null || echo 0)
  if [ "$ENI_COUNT" = "0" ] || [ "$ENI_COUNT" = "None" ]; then
    echo "    ENIs released."
    break
  fi
  echo "    $ENI_COUNT ELB ENI(s) still attached, waiting 5s... ($((i*5))s elapsed)"
  sleep 5
done
echo ""

# ── 1. Delete EKS node groups (must go before the cluster) ───────────────────
echo "==> [1/7] Deleting EKS node groups..."
NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER" \
  --query 'nodegroups[]' --output text 2>/dev/null || true)

if [ -n "$NODEGROUPS" ]; then
  for NG in $NODEGROUPS; do
    echo "    Deleting node group: $NG"
    aws eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" \
      --output text --query 'nodegroup.status' >/dev/null 2>&1 || true
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
      --output text --query 'addon.status' >/dev/null 2>&1 || true
  done
else
  echo "    No add-ons found."
fi

# ── 3. Delete the EKS cluster ────────────────────────────────────────────────
echo ""
echo "==> [3/7] Deleting EKS cluster: $CLUSTER..."
if aws eks delete-cluster --name "$CLUSTER" --output text --query 'cluster.status' >/dev/null 2>&1; then
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
    --output text --query 'Name' >/dev/null 2>&1 && echo "    Deleted." || echo "    Not found or already deleted."
done

# ── 5. Delete ECR repositories ───────────────────────────────────────────────
echo ""
echo "==> [5/7] Deleting ECR repositories..."
for REPO in \
  finance-app/gateway-api finance-app/account-service finance-app/transaction-service \
  finance-app/fraud-detection finance-app/notification-service finance-app/batch-processor; do
  echo "    Deleting ECR repo: $REPO"
  aws ecr delete-repository --repository-name "$REPO" --force \
    --output text --query 'repository.repositoryName' >/dev/null 2>&1 && \
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
