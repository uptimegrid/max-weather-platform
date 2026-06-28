output "cluster_name" {
  value = module.mw-prd-apse1-eks-01.cluster_name
}

output "log_group_name" {
  value = module.mw-prd-apse1-cw-01.application_log_group_name
}

output "log_shipper_role_arn" {
  value       = module.mw-prd-apse1-logshipper-01.role_arn
  description = "IRSA role ARN annotated on the aws-for-fluent-bit service account (used by scripts/install-cluster-addons.sh)."
}

output "repository_url" {
  value = module.mw-prd-apse1-ecr-01.repository_url
}

output "cluster_endpoint" {
  value = module.mw-prd-apse1-eks-01.cluster_endpoint
}

output "jenkins_controller_instance_id" {
  value = module.mw-prd-apse1-ec2-jenkins-ctrl-01.instance_id
}

output "jenkins_agent_instance_id" {
  value = module.mw-prd-apse1-ec2-jenkins-agent-01.instance_id
}

output "jenkins_agent_role_arn" {
  value = module.mw-prd-apse1-ec2-jenkins-agent-01.iam_role_arn
}

output "jenkins_controller_private_ip" {
  value       = module.mw-prd-apse1-ec2-jenkins-ctrl-01.private_ip
  description = "Controller private IP. Pass it as CONTROLLER_URL=http://<ip>:8080 to scripts/install-jenkins-agent.sh."
}

output "jenkins_access_hint" {
  value       = "Jenkins UI at http://${module.mw-prd-apse1-ec2-jenkins-ctrl-01.private_ip}:8080 — it is private; reach it via SSM port-forwarding. OS login uses SSM Session Manager (no SSH key). Install/configure Jenkins with scripts/install-jenkins-controller.sh then scripts/install-jenkins-agent.sh."
  description = "How to reach and set up the private Jenkins controller."
}

output "api_endpoint" {
  value = module.mw-prd-apse1-api-01.api_endpoint
}

output "oauth_token_endpoint" {
  value = module.mw-prd-apse1-cognito-01.oauth_token_endpoint
}

output "oauth_client_id" {
  value = module.mw-prd-apse1-cognito-01.oauth_client_id
}

output "oauth_scope" {
  value = module.mw-prd-apse1-cognito-01.oauth_scope
}

output "oauth_client_secret" {
  value     = module.mw-prd-apse1-cognito-01.oauth_client_secret
  sensitive = true
}
