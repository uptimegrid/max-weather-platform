module "mw-stg-apse1-vpc-01" {
  source = "../../../../terraform-shared-modules/aws/network/vpc"

  environment  = "staging"
  name_prefix  = "mw-stg-apse1"        # names the VPC / IGW / NAT / route tables
  cluster_name = "mw-stg-apse1-eks-01" # tags subnets for EKS / load balancer discovery
  vpc_cidr     = "10.10.0.0/20"

  # Staging is cost-lean (2 AZ). Each subnet is explicit: name (the map key) +
  # CIDR + AZ + tier. EKS spans both AZs. Jenkins runs only in production (it is
  # the only environment actually deployed to AWS), so staging has no EC2 subnet.
  subnets = {
    "mw-stg-apse1-snet-pub-01"     = { cidr = "10.10.0.0/24", az = "ap-southeast-1a", tier = "public" }
    "mw-stg-apse1-snet-pub-02"     = { cidr = "10.10.1.0/24", az = "ap-southeast-1b", tier = "public" }
    "mw-stg-apse1-snet-eks-prv-01" = { cidr = "10.10.4.0/24", az = "ap-southeast-1a", tier = "private" }
    "mw-stg-apse1-snet-eks-prv-02" = { cidr = "10.10.5.0/24", az = "ap-southeast-1b", tier = "private" }
  }

  # Single zonal NAT Gateway to save cost in staging (accepts an AZ egress SPOF).
  # Production uses "regional" for full 24/7 HA.
  nat_gateway_mode = "single"
}

module "mw-stg-apse1-ecr-01" {
  source = "../../../../terraform-shared-modules/aws/compute/ecr"

  name = "mw-stg-apse1-ecr-01"
  # Staging keeps module defaults (MUTABLE tags, force_delete = true) for fast iteration.
}

# Self-hosted Jenkins (controller + agent) runs only in the production
# environment, since production is the environment actually deployed to AWS.
# See terraform/environments/production/main.tf for the EC2 definitions.

module "mw-stg-apse1-eks-01" {
  source = "../../../../terraform-shared-modules/aws/compute/eks"

  environment    = "staging"
  name_prefix    = "mw-stg-apse1"
  cluster_name   = "mw-stg-apse1-eks-01"
  kubernetes_ver = "1.30"
  vpc_id         = module.mw-stg-apse1-vpc-01.vpc_id
  private_subnet_ids = [
    module.mw-stg-apse1-vpc-01.private_subnet_ids_by_name["mw-stg-apse1-snet-eks-prv-01"],
    module.mw-stg-apse1-vpc-01.private_subnet_ids_by_name["mw-stg-apse1-snet-eks-prv-02"],
  ]
  node_group_name         = "mw-stg-apse1-ng-01"
  node_instance_types     = ["t3.medium"]
  node_capacity_type      = "SPOT" # Cheaper interruptible capacity is acceptable in staging.
  node_desired_size       = 2
  node_min_size           = 2
  node_max_size           = 4
  node_disk_size          = 30
  endpoint_private_access = true
  endpoint_public_access  = true
  cluster_log_types       = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Jenkins lives in production. If staging is ever deployed and managed by that
  # Jenkins agent, add the production output `jenkins_agent_role_arn` here.
  cluster_admin_principal_arns = []
}

module "mw-stg-apse1-cw-01" {
  source = "../../../../terraform-shared-modules/aws/monitor/cloudwatch"

  name_prefix           = "mw-stg-apse1"
  cluster_name          = "mw-stg-apse1-eks-01"
  log_retention_in_days = 14
}

module "mw-stg-apse1-logshipper-01" {
  source = "../../../../terraform-shared-modules/aws/monitor/irsa-log-shipper"

  name_prefix               = "mw-stg-apse1"
  oidc_provider_arn         = module.mw-stg-apse1-eks-01.oidc_provider_arn
  oidc_provider_url         = module.mw-stg-apse1-eks-01.oidc_provider_url
  application_log_group_arn = module.mw-stg-apse1-cw-01.application_log_group_arn
  cluster_log_group_arn     = module.mw-stg-apse1-cw-01.cluster_log_group_arn
}

module "mw-stg-apse1-cognito-01" {
  source = "../../../../terraform-shared-modules/aws/identity/cognito"

  name_prefix                = "mw-stg-apse1"
  domain_prefix              = "mw-stg-apse1-auth-01"
  resource_server_identifier = "https://api.max-weather.staging"
  oauth_scope_name           = "invoke"
}

# --- Private API integration: API Gateway -> VPC Link -> internal ingress NLB ---
# Both environments use the same design: API Gateway is the only public entry
# point and reaches the cluster privately through a VPC Link to the internal NLB.
# The internal NLB is created by the ingress-nginx Helm release, so it is looked
# up by tag. Bootstrap ordering (see docs/architecture.md): create the VPC/EKS
# first (targeted apply), deploy ingress-nginx so the internal NLB exists, then
# run a full apply to wire the VPC Link to the NLB listener.
#
# Both environments run in the same AWS account, so the lookup is scoped to THIS
# cluster with the `kubernetes.io/cluster/<name> = owned` tag the AWS in-tree
# cloud provider stamps on the NLB. Without it the service-name tag alone would
# match the staging AND production NLBs.
data "aws_lb" "ingress" {
  tags = {
    "kubernetes.io/service-name"                = "ingress-nginx/ingress-nginx-controller"
    "kubernetes.io/cluster/mw-stg-apse1-eks-01" = "owned"
  }
}

data "aws_lb_listener" "ingress" {
  load_balancer_arn = data.aws_lb.ingress.arn
  port              = 80
}

# Security group attached to the VPC Link ENIs.
resource "aws_security_group" "mw-stg-apse1-sg-vpclink-01" {
  name        = "mw-stg-apse1-sg-vpclink-01"
  description = "API Gateway VPC Link ENIs reaching the internal ingress NLB"
  vpc_id      = module.mw-stg-apse1-vpc-01.vpc_id

  egress {
    description = "To the internal NLB and EKS nodes within the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [module.mw-stg-apse1-vpc-01.vpc_cidr]
  }

  tags = { Name = "mw-stg-apse1-sg-vpclink-01" }
}

# Allow the VPC Link to reach the NodePort range on the EKS cluster security
# group. Note: depending on how ingress-nginx targets nodes, the EKS-managed
# node security group may also need this rule at deploy time.
resource "aws_security_group_rule" "vpclink_to_nodes" {
  type                     = "ingress"
  description              = "NodePort range from the API Gateway VPC Link"
  from_port                = 30000
  to_port                  = 32767
  protocol                 = "tcp"
  security_group_id        = module.mw-stg-apse1-eks-01.cluster_security_group_id
  source_security_group_id = aws_security_group.mw-stg-apse1-sg-vpclink-01.id
}

module "mw-stg-apse1-api-01" {
  source = "../../../../terraform-shared-modules/aws/edge/api-gateway"

  name_prefix = "mw-stg-apse1"
  api_name    = "mw-stg-apse1-api-01"

  # Private path: API Gateway -> VPC Link -> internal NLB listener.
  private_integration = true
  vpc_link_subnet_ids = [
    module.mw-stg-apse1-vpc-01.private_subnet_ids_by_name["mw-stg-apse1-snet-eks-prv-01"],
    module.mw-stg-apse1-vpc-01.private_subnet_ids_by_name["mw-stg-apse1-snet-eks-prv-02"],
  ]
  vpc_link_security_group_ids = [aws_security_group.mw-stg-apse1-sg-vpclink-01.id]
  nlb_listener_arn            = data.aws_lb_listener.ingress.arn

  oauth_issuer_url             = module.mw-stg-apse1-cognito-01.oauth_issuer_url
  oauth_audience               = module.mw-stg-apse1-cognito-01.oauth_audience
  oauth_scope                  = module.mw-stg-apse1-cognito-01.oauth_scope
  access_log_retention_in_days = 14
}
