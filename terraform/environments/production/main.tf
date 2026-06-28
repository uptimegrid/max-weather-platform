module "mw-prd-apse1-vpc-01" {
  source = "../../../../terraform-shared-modules/aws/network/vpc"

  environment  = "production"
  name_prefix  = "mw-prd-apse1"        # names the VPC / IGW / NAT / route tables
  cluster_name = "mw-prd-apse1-eks-01" # tags subnets for EKS / load balancer discovery
  vpc_cidr     = "10.20.0.0/20"

  # Production is full HA across 3 AZs and has NO public subnets: the Regional
  # NAT Gateway is a VPC-level resource (needs no public subnet to host it) and
  # the only public entry point is API Gateway (AWS-managed, outside the VPC)
  # reaching an internal NLB via VPC Link. Each subnet is explicit: name (the map
  # key) + CIDR + AZ + tier. EKS spans all three AZs; Jenkins (EC2) has its own
  # private subnet.
  subnets = {
    "mw-prd-apse1-snet-eks-prv-01" = { cidr = "10.20.4.0/24", az = "ap-southeast-1a", tier = "private" }
    "mw-prd-apse1-snet-eks-prv-02" = { cidr = "10.20.5.0/24", az = "ap-southeast-1b", tier = "private" }
    "mw-prd-apse1-snet-eks-prv-03" = { cidr = "10.20.6.0/24", az = "ap-southeast-1c", tier = "private" }
    "mw-prd-apse1-snet-ec2-prv-01" = { cidr = "10.20.8.0/24", az = "ap-southeast-1a", tier = "private" }
  }

  # Regional NAT Gateway: a single VPC-level NAT that automatically spans all AZs
  # with workloads (full 24/7 HA, no per-AZ NAT or public subnet to manage). It
  # gets its own AWS-managed route table with a route to the IGW for egress.
  nat_gateway_mode = "regional"

  # Explicit route table defined here (not hidden in the module): all 4 private
  # subnets share rt-prv-01 (default route -> Regional NAT). There is no public
  # route table because there are no public subnets.
  route_tables = {
    "mw-prd-apse1-rt-prv-01" = {
      routes = [
        { destination_cidr_block = "0.0.0.0/0", target = "nat" },
      ]
    }
  }

  # Which subnet associates with which route table (subnet name => route table name).
  route_table_associations = {
    "mw-prd-apse1-snet-eks-prv-01" = "mw-prd-apse1-rt-prv-01"
    "mw-prd-apse1-snet-eks-prv-02" = "mw-prd-apse1-rt-prv-01"
    "mw-prd-apse1-snet-eks-prv-03" = "mw-prd-apse1-rt-prv-01"
    "mw-prd-apse1-snet-ec2-prv-01" = "mw-prd-apse1-rt-prv-01"
  }
}

module "mw-prd-apse1-ecr-01" {
  source = "../../../../terraform-shared-modules/aws/compute/ecr"

  name = "mw-prd-apse1-ecr-01"

  # Production hardening: immutable tags for image provenance and no force-delete
  # so a repository with images cannot be removed accidentally.
  image_tag_mutability  = "IMMUTABLE"
  force_delete          = false
  image_retention_count = 30
}


module "mw-prd-apse1-ec2-jenkins-ctrl-01" {
  source = "../../../../terraform-shared-modules/aws/compute/ec2"

  name          = "mw-prd-apse1-ec2-jenkins-ctrl-01"
  vpc_id        = module.mw-prd-apse1-vpc-01.vpc_id
  subnet_id     = module.mw-prd-apse1-vpc-01.private_subnet_ids_by_name["mw-prd-apse1-snet-ec2-prv-01"]
  instance_type = "t3.small"

  iam_managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]

  ingress_rules = [
    {
      description = "Jenkins UI from within the VPC"
      from_port   = 8080
      to_port     = 8080
      protocol    = "tcp"
      cidr_blocks = [module.mw-prd-apse1-vpc-01.vpc_cidr]
    },
    {
      description = "JNLP agent connections from within the VPC"
      from_port   = 50000
      to_port     = 50000
      protocol    = "tcp"
      cidr_blocks = [module.mw-prd-apse1-vpc-01.vpc_cidr]
    },
  ]

  # The instance is a plain VM reached via SSM Session Manager (no SSH key). Jenkins
  # is installed/configured afterwards with scripts/install-jenkins-controller.sh.
  # Ensure the VPC (subnets, NAT, routes) exists before the instance is created.
  depends_on = [module.mw-prd-apse1-vpc-01]
}

module "mw-prd-apse1-ec2-jenkins-agent-01" {
  source = "../../../../terraform-shared-modules/aws/compute/ec2"

  name          = "mw-prd-apse1-ec2-jenkins-agent-01"
  vpc_id        = module.mw-prd-apse1-vpc-01.vpc_id
  subnet_id     = module.mw-prd-apse1-vpc-01.private_subnet_ids_by_name["mw-prd-apse1-snet-ec2-prv-01"]
  instance_type = "c7i-flex.large" # free-tier-eligible (2 vCPU / 4 GiB) for Terraform + Docker builds

  iam_managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser",
  ]

  # Plain VM reached via SSM Session Manager (no SSH key). The build toolchain and
  # agent join are installed afterwards with scripts/install-jenkins-agent.sh.
  # Ensure the VPC (subnets, NAT, routes) exists before the instance is created.
  depends_on = [module.mw-prd-apse1-vpc-01]
}

# The agent runs Terraform for the WHOLE platform, so its role needs broad
# permissions. For this assessment we attach AdministratorAccess to keep it
# simple. In a production setup, scope this down to a least-privilege deploy
# policy, or have the agent assume a dedicated Terraform deploy role so the
# instance profile itself stays minimal (separation of duties).
resource "aws_iam_role_policy_attachment" "jenkins_agent_deploy" {
  role       = module.mw-prd-apse1-ec2-jenkins-agent-01.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

module "mw-prd-apse1-eks-01" {
  source = "../../../../terraform-shared-modules/aws/compute/eks"

  depends_on = [module.mw-prd-apse1-vpc-01]

  environment    = "production"
  name_prefix    = "mw-prd-apse1"
  cluster_name   = "mw-prd-apse1-eks-01"
  kubernetes_ver = "1.35"
  vpc_id         = module.mw-prd-apse1-vpc-01.vpc_id
  private_subnet_ids = [
    module.mw-prd-apse1-vpc-01.private_subnet_ids_by_name["mw-prd-apse1-snet-eks-prv-01"],
    module.mw-prd-apse1-vpc-01.private_subnet_ids_by_name["mw-prd-apse1-snet-eks-prv-02"],
    module.mw-prd-apse1-vpc-01.private_subnet_ids_by_name["mw-prd-apse1-snet-eks-prv-03"],
  ]
  node_group_name         = "mw-prd-apse1-ng-01"
  node_instance_types     = ["c7i-flex.large"] # free-tier-eligible (2 vCPU / 4 GiB) for ingress/metrics/fluent-bit + app
  node_capacity_type      = "ON_DEMAND"        # Stable capacity for the 24/7 production workload.
  node_desired_size       = 3                  # one node per AZ across the three private subnets (24/7 cross-AZ HA)
  node_min_size           = 3                  # never drop below one node per AZ
  node_max_size           = 4
  node_disk_size          = 30
  endpoint_private_access = true
  # Private-only API endpoint: reachable from inside the VPC (e.g. the Jenkins
  # agent) but not the public internet. Re-enable public access from the console
  # temporarily when external kubectl access is needed.
  endpoint_public_access = false
  cluster_log_types      = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Grant the Jenkins agent EKS cluster-admin so it can run kubectl during deploys.
  cluster_admin_principal_arns = [module.mw-prd-apse1-ec2-jenkins-agent-01.iam_role_arn]

  # Ingress on the cluster security group (owned by the EKS module). The agent
  # reaches the private API endpoint on 443, and the API Gateway VPC Link reaches
  # the NodePort range. Defined here as data (which SG is trusted), implemented by
  # the module that owns the SG.
  cluster_sg_ingress_rules = {
    jenkins_agent_api = {
      description              = "EKS API server (443) from the Jenkins build agent"
      from_port                = 443
      to_port                  = 443
      source_security_group_id = module.mw-prd-apse1-ec2-jenkins-agent-01.security_group_id
    }
    vpclink_nodeport = {
      description              = "NodePort range from the API Gateway VPC Link"
      from_port                = 30000
      to_port                  = 32767
      source_security_group_id = aws_security_group.mw-prd-apse1-sg-vpclink-01.id
    }
  }
}

module "mw-prd-apse1-cw-01" {
  source = "../../../../terraform-shared-modules/aws/monitor/cloudwatch"

  name_prefix           = "mw-prd-apse1"
  cluster_name          = "mw-prd-apse1-eks-01"
  log_retention_in_days = 14
}

module "mw-prd-apse1-logshipper-01" {
  source = "../../../../terraform-shared-modules/aws/monitor/irsa-log-shipper"

  name_prefix               = "mw-prd-apse1"
  oidc_provider_arn         = module.mw-prd-apse1-eks-01.oidc_provider_arn
  oidc_provider_url         = module.mw-prd-apse1-eks-01.oidc_provider_url
  application_log_group_arn = module.mw-prd-apse1-cw-01.application_log_group_arn
  cluster_log_group_arn     = module.mw-prd-apse1-cw-01.cluster_log_group_arn
}

module "mw-prd-apse1-cognito-01" {
  source = "../../../../terraform-shared-modules/aws/identity/cognito"

  name_prefix                = "mw-prd-apse1"
  domain_prefix              = "mw-prd-apse1-auth-01"
  resource_server_identifier = "https://api.max-weather.production"
  oauth_scope_name           = "invoke"

  # Production hardening: protect the user pool from accidental deletion.
  deletion_protection = "ACTIVE"
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
    "kubernetes.io/cluster/mw-prd-apse1-eks-01" = "owned"
  }
}

data "aws_lb_listener" "ingress" {
  load_balancer_arn = data.aws_lb.ingress.arn
  port              = 80
}

# Security group attached to the VPC Link ENIs.
resource "aws_security_group" "mw-prd-apse1-sg-vpclink-01" {
  depends_on = [module.mw-prd-apse1-vpc-01]

  name        = "mw-prd-apse1-sg-vpclink-01"
  description = "API Gateway VPC Link ENIs reaching the internal ingress NLB"
  vpc_id      = module.mw-prd-apse1-vpc-01.vpc_id

  egress {
    description = "To the internal NLB and EKS nodes within the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [module.mw-prd-apse1-vpc-01.vpc_cidr]
  }

  tags = { Name = "mw-prd-apse1-sg-vpclink-01" }
}

module "mw-prd-apse1-api-01" {
  source = "../../../../terraform-shared-modules/aws/edge/api-gateway"

  name_prefix = "mw-prd-apse1"
  api_name    = "mw-prd-apse1-api-01"

  # Private path: API Gateway -> VPC Link -> internal NLB listener.
  private_integration = true
  vpc_link_subnet_ids = [
    module.mw-prd-apse1-vpc-01.private_subnet_ids_by_name["mw-prd-apse1-snet-eks-prv-01"],
    module.mw-prd-apse1-vpc-01.private_subnet_ids_by_name["mw-prd-apse1-snet-eks-prv-02"],
    module.mw-prd-apse1-vpc-01.private_subnet_ids_by_name["mw-prd-apse1-snet-eks-prv-03"],
  ]
  vpc_link_security_group_ids = [aws_security_group.mw-prd-apse1-sg-vpclink-01.id]
  nlb_listener_arn            = data.aws_lb_listener.ingress.arn

  oauth_issuer_url             = module.mw-prd-apse1-cognito-01.oauth_issuer_url
  oauth_audience               = module.mw-prd-apse1-cognito-01.oauth_audience
  oauth_scope                  = module.mw-prd-apse1-cognito-01.oauth_scope
  access_log_retention_in_days = 14
}


module "mw-prd-apse1-dashboard-01" {
  source = "../../../../terraform-shared-modules/aws/monitor/dashboard"

  name_prefix                = "mw-prd-apse1"
  region                     = "ap-southeast-1"
  api_id                     = module.mw-prd-apse1-api-01.api_id
  application_log_group_name = module.mw-prd-apse1-cw-01.application_log_group_name
  access_log_group_name      = module.mw-prd-apse1-api-01.access_log_group_name
  cluster_log_group_name     = module.mw-prd-apse1-cw-01.cluster_log_group_name
}
