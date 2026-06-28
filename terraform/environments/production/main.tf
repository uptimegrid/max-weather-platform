module "mw-prd-apse1-vpc-01" {
  source = "../../../../terraform-shared-modules/aws/network/vpc"

  environment  = "production"
  name_prefix  = "mw-prd-apse1"
  cluster_name = "mw-prd-apse1-eks-01"
  vpc_cidr     = "10.20.0.0/20"

  subnets = {
    "mw-prd-apse1-snet-eks-prv-01" = { cidr = "10.20.4.0/24", az = "ap-southeast-1a", tier = "private" }
    "mw-prd-apse1-snet-eks-prv-02" = { cidr = "10.20.5.0/24", az = "ap-southeast-1b", tier = "private" }
    "mw-prd-apse1-snet-eks-prv-03" = { cidr = "10.20.6.0/24", az = "ap-southeast-1c", tier = "private" }
    "mw-prd-apse1-snet-ec2-prv-01" = { cidr = "10.20.8.0/24", az = "ap-southeast-1a", tier = "private" }
  }

  nat_gateway_mode = "regional"

  route_tables = {
    "mw-prd-apse1-rt-prv-01" = {
      routes = [
        { destination_cidr_block = "0.0.0.0/0", target = "nat" },
      ]
    }
  }

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

  depends_on = [module.mw-prd-apse1-vpc-01]
}

module "mw-prd-apse1-ec2-jenkins-agent-01" {
  source = "../../../../terraform-shared-modules/aws/compute/ec2"

  name          = "mw-prd-apse1-ec2-jenkins-agent-01"
  vpc_id        = module.mw-prd-apse1-vpc-01.vpc_id
  subnet_id     = module.mw-prd-apse1-vpc-01.private_subnet_ids_by_name["mw-prd-apse1-snet-ec2-prv-01"]
  instance_type = "c7i-flex.large"

  iam_managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser",
  ]

  depends_on = [module.mw-prd-apse1-vpc-01]
}

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
  node_instance_types     = ["c7i-flex.large"]
  node_capacity_type      = "ON_DEMAND"
  node_desired_size       = 3
  node_min_size           = 3
  node_max_size           = 4
  node_disk_size          = 30
  endpoint_private_access = true

  endpoint_public_access = false
  cluster_log_types      = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  cluster_admin_principal_arns = [module.mw-prd-apse1-ec2-jenkins-agent-01.iam_role_arn]

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

  deletion_protection = "ACTIVE"
}

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

locals {
  dashboard_api_id    = module.mw-prd-apse1-api-01.api_id
  dashboard_api_stage = "$default"

  dashboard_rows = [
    {
      height = 2
      widgets = [
        {
          type       = "text"
          width      = 24
          properties = { markdown = "# mw-prd-apse1 - Max Weather API\nKey operational metrics for the public API Gateway endpoint and the application running on EKS." }
        },
      ]
    },
    {
      height = 4
      widgets = [
        {
          type  = "metric"
          width = 6
          properties = {
            title                = "Total requests"
            view                 = "singleValue"
            stat                 = "Sum"
            period               = 300
            setPeriodToTimeRange = true
            metrics              = [["AWS/ApiGateway", "Count", "ApiId", local.dashboard_api_id, "Stage", local.dashboard_api_stage]]
          }
        },
        {
          type  = "metric"
          width = 6
          properties = {
            title                = "Total 5xx errors"
            view                 = "singleValue"
            stat                 = "Sum"
            period               = 300
            setPeriodToTimeRange = true
            metrics              = [["AWS/ApiGateway", "5xx", "ApiId", local.dashboard_api_id, "Stage", local.dashboard_api_stage]]
          }
        },
        {
          type  = "metric"
          width = 6
          properties = {
            title                = "Error rate %"
            view                 = "singleValue"
            period               = 300
            setPeriodToTimeRange = true
            metrics = [
              [{ expression = "100*(m2/m1)", label = "Error rate %", id = "e1" }],
              ["AWS/ApiGateway", "Count", "ApiId", local.dashboard_api_id, "Stage", local.dashboard_api_stage, { id = "m1", stat = "Sum", visible = false }],
              ["AWS/ApiGateway", "5xx", "ApiId", local.dashboard_api_id, "Stage", local.dashboard_api_stage, { id = "m2", stat = "Sum", visible = false }],
            ]
          }
        },
        {
          type  = "metric"
          width = 6
          properties = {
            title                = "Avg latency (ms)"
            view                 = "singleValue"
            stat                 = "Average"
            period               = 300
            setPeriodToTimeRange = true
            metrics              = [["AWS/ApiGateway", "Latency", "ApiId", local.dashboard_api_id, "Stage", local.dashboard_api_stage]]
          }
        },
      ]
    },
    {
      height = 6
      widgets = [
        {
          type  = "metric"
          width = 12
          properties = {
            title  = "API requests and errors"
            view   = "timeSeries"
            stat   = "Sum"
            period = 60
            metrics = [
              ["AWS/ApiGateway", "Count", "ApiId", local.dashboard_api_id, "Stage", local.dashboard_api_stage, { label = "Requests" }],
              ["AWS/ApiGateway", "4xx", "ApiId", local.dashboard_api_id, "Stage", local.dashboard_api_stage, { label = "4xx" }],
              ["AWS/ApiGateway", "5xx", "ApiId", local.dashboard_api_id, "Stage", local.dashboard_api_stage, { label = "5xx" }],
            ]
          }
        },
        {
          type  = "metric"
          width = 12
          properties = {
            title  = "Latency (ms)"
            view   = "timeSeries"
            period = 60
            metrics = [
              ["AWS/ApiGateway", "Latency", "ApiId", local.dashboard_api_id, "Stage", local.dashboard_api_stage, { stat = "Average", label = "Latency avg" }],
              ["AWS/ApiGateway", "Latency", "ApiId", local.dashboard_api_id, "Stage", local.dashboard_api_stage, { stat = "p99", label = "Latency p99" }],
              ["AWS/ApiGateway", "IntegrationLatency", "ApiId", local.dashboard_api_id, "Stage", local.dashboard_api_stage, { stat = "Average", label = "Integration latency avg" }],
            ]
          }
        },
      ]
    },
    {
      height = 6
      widgets = [
        {
          type  = "log"
          width = 24
          properties = {
            title = "Application weather requests"
            view  = "table"
            query = "SOURCE '${module.mw-prd-apse1-cw-01.application_log_group_name}' | fields @timestamp, @message | sort @timestamp desc | limit 50"
          }
        },
      ]
    },
    {
      height = 6
      widgets = [
        {
          type  = "log"
          width = 24
          properties = {
            title = "API Gateway access logs by status"
            view  = "table"
            query = "SOURCE '${module.mw-prd-apse1-api-01.access_log_group_name}' | stats count(*) as requests by status | sort requests desc"
          }
        },
      ]
    },
    {
      height = 6
      widgets = [
        {
          type  = "log"
          width = 24
          properties = {
            title = "EKS control-plane logs"
            view  = "table"
            query = "SOURCE '${module.mw-prd-apse1-cw-01.cluster_log_group_name}' | fields @timestamp, @logStream, @message | sort @timestamp desc | limit 50"
          }
        },
      ]
    },
  ]
}

module "mw-prd-apse1-dashboard-01" {
  source = "../../../../terraform-shared-modules/aws/monitor/dashboard"

  dashboard_name = "mw-prd-apse1-dashboard-01"
  region         = "ap-southeast-1"
  rows           = local.dashboard_rows
}
