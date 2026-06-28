#!/usr/bin/env bash
# Install the cluster add-ons (Helm) that are NOT managed by Terraform:
#   1. ingress-nginx      -> internal NLB that the API Gateway VPC Link binds to
#   2. metrics-server     -> required by the HorizontalPodAutoscaler
#   3. aws-for-fluent-bit -> ships pod logs to the CloudWatch group (via IRSA)
#
# Run ONCE per cluster, AFTER the EKS cluster exists and BEFORE the full
# Terraform apply that wires the API Gateway VPC Link to the ingress NLB.
#
# Requirements: aws CLI v2, kubectl, helm. Run from the max-weather-platform repo
# root with credentials for the target account.
#
# Usage:
#   ENVIRONMENT=production ./scripts/install-cluster-addons.sh
set -euo pipefail

ENVIRONMENT="${ENVIRONMENT:-production}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
TF_DIR="terraform/environments/${ENVIRONMENT}"

# Values the add-ons need, read from Terraform outputs (so nothing is hard-coded).
CLUSTER_NAME="$(terraform -chdir="${TF_DIR}" output -raw cluster_name)"
LOG_GROUP="$(terraform -chdir="${TF_DIR}" output -raw log_group_name)"
LOG_SHIPPER_ROLE_ARN="$(terraform -chdir="${TF_DIR}" output -raw log_shipper_role_arn)"

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

# 1. ingress-nginx — provisions the internal NLB (see kubernetes/ingress-controller/values.yaml).
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  -f kubernetes/ingress-controller/values.yaml

# 2. metrics-server — HPA prerequisite.
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system

# 3. aws-for-fluent-bit — CloudWatch log shipping via IRSA. The role ARN, region
#    and log group come from Terraform outputs, so the placeholder values.yaml
#    stays clean and free of account-specific values.
helm repo add eks https://aws.github.io/eks-charts
helm upgrade --install aws-for-fluent-bit eks/aws-for-fluent-bit \
  --namespace kube-system \
  -f kubernetes/logging/values.yaml \
  --set-string serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${LOG_SHIPPER_ROLE_ARN}" \
  --set-string cloudWatchLogs.region="${AWS_REGION}" \
  --set-string cloudWatchLogs.logGroupName="${LOG_GROUP}"

echo "Cluster add-ons installed for ${ENVIRONMENT} (${CLUSTER_NAME})."
echo "Confirm the internal NLB exists:"
echo "  kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide"
echo "Then run the full 'terraform apply' to wire the API Gateway VPC Link."
