output "cluster_name" {
  value = module.mw-stg-apse1-eks-01.cluster_name
}

output "log_group_name" {
  value = module.mw-stg-apse1-cw-01.application_log_group_name
}

output "repository_url" {
  value = module.mw-stg-apse1-ecr-01.repository_url
}

output "cluster_endpoint" {
  value = module.mw-stg-apse1-eks-01.cluster_endpoint
}

output "api_endpoint" {
  value = module.mw-stg-apse1-api-01.api_endpoint
}

output "oauth_token_endpoint" {
  value = module.mw-stg-apse1-cognito-01.oauth_token_endpoint
}

output "oauth_client_id" {
  value = module.mw-stg-apse1-cognito-01.oauth_client_id
}

output "oauth_scope" {
  value = module.mw-stg-apse1-cognito-01.oauth_scope
}

output "oauth_client_secret" {
  value     = module.mw-stg-apse1-cognito-01.oauth_client_secret
  sensitive = true
}
