# =============================================================================
# Finance Sample App — Terraform Outputs
# =============================================================================
# After `terraform apply`, use these outputs to:
#   - Configure kubectl: make tf-configure-kubectl  (runs: eval "$(terraform output -raw kubeconfig_command)")
#   - Tag Docker images with the ECR registry URL before pushing
#   - Pass the Datadog integration role ARN into the Datadog AWS integration UI
# =============================================================================

# =============================================================================
# EKS CLUSTER
# =============================================================================

output "cluster_endpoint" {
  description = "HTTPS endpoint of the EKS API server. Use with kubectl and the Kubernetes Terraform provider."
  value       = module.eks.cluster_endpoint
}

output "cluster_name" {
  description = "Name of the provisioned EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the EKS cluster. Required for kubeconfig."
  # Useful when configuring the Kubernetes Terraform provider directly.
  # The standard kubectl workflow (make tf-configure-kubectl) does not need this
  # — aws eks update-kubeconfig fetches the CA data automatically.
  value     = module.eks.cluster_certificate_authority_data
  sensitive = true
}

output "cluster_arn" {
  description = "ARN of the EKS cluster — use for IAM policy conditions and CloudTrail filtering."
  value       = module.eks.cluster_arn
}

output "kubeconfig_command" {
  description = "Run this command to configure kubectl after the cluster is provisioned."
  value = var.aws_profile != "" ? (
    "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region} --profile ${var.aws_profile}"
    ) : (
    "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
  )
}

output "deploy_command" {
  description = "Run this after configuring kubectl to deploy the Finance app to EKS."
  value       = "make deploy-k8s"
}

# =============================================================================
# ECR REPOSITORIES
# =============================================================================

output "ecr_registry_urls" {
  description = <<-EOT
    Map of service name → ECR repository URL for all Finance microservices.

    Tag and push images with:
      docker tag <service>:latest <url>:$(git rev-parse --short HEAD)
      docker push <url>:$(git rev-parse --short HEAD)

    Set DD_VERSION=$(git rev-parse --short HEAD) to tie Datadog Deployment Tracking
    to the exact image tag. Docs: https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/
  EOT
  value = {
    for service, repo in aws_ecr_repository.services :
    service => repo.repository_url
  }
}

output "ecr_registry_id" {
  description = "ECR registry ID (same as AWS account ID) — use for docker login."
  value       = data.aws_caller_identity.current.account_id
}

output "ecr_login_command" {
  description = "Run this command to authenticate Docker with ECR before pushing images."
  value       = "aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

# =============================================================================
# DATADOG INTEGRATION
# =============================================================================

output "dd_integration_role_arn" {
  description = <<-EOT
    ARN of the IAM role assumed by Datadog for the AWS integration.

    Provide this ARN when configuring the Datadog AWS integration at:
    https://app.datadoghq.com/integrations/amazon-web-services

    Or pass it to the datadog_integration_aws Terraform resource (see main.tf
    commented block) as role_name after uncommenting the Datadog provider.
  EOT
  value       = aws_iam_role.datadog_integration.arn
}

output "dd_integration_role_name" {
  description = "Name of the IAM role for the Datadog AWS integration — used as role_name in the Datadog provider."
  value       = aws_iam_role.datadog_integration.name
}

# =============================================================================
# SECRETS MANAGER — ARNs only (never output secret values)
# =============================================================================

output "dd_app_key_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Datadog App key. Populate with: aws secretsmanager put-secret-value --secret-id <arn> --secret-string your-app-key. Used by the Datadog Terraform provider in deploy/terraform/datadog/."
  value       = aws_secretsmanager_secret.dd_app_key.arn
}

output "dd_api_key_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Datadog API key. Use 'terraform output dd_api_key_secret_arn' to get the ARN, then populate the value with: aws secretsmanager put-secret-value --secret-id <arn> --secret-string your-api-key"
  value       = aws_secretsmanager_secret.dd_api_key.arn
}

output "datadog_dbm_password_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Datadog DBM PostgreSQL monitoring password. Populate with: aws secretsmanager put-secret-value --secret-id <arn> --secret-string your-password. Reference in the Agent as: password: ENC[k8s_secret,datadog-dbm-password]"
  value       = aws_secretsmanager_secret.datadog_dbm_password.arn
}

# =============================================================================
# NETWORKING
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC created for the Finance app EKS cluster."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs — EKS worker nodes and database instances run here."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs — load balancers and NAT gateways."
  value       = module.vpc.public_subnets
}

# =============================================================================
# CLOUDWATCH
# =============================================================================

output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch log group receiving EKS application logs. Configure the Lambda forwarder subscription against this group to ship logs to Datadog."
  value       = aws_cloudwatch_log_group.finance_app.name
}

output "cloudwatch_log_group_arn" {
  description = "ARN of the CloudWatch log group — used in the Lambda subscription filter (see main.tf commented block)."
  value       = aws_cloudwatch_log_group.finance_app.arn
}

# =============================================================================
# ACCOUNT
# =============================================================================

output "aws_account_id" {
  description = "AWS account ID — used when configuring the Datadog AWS integration and constructing ECR URIs."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "AWS region where all resources are deployed."
  value       = var.aws_region
}
