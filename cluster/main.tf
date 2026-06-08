###############################################################################
# EKS 集群创建（控制面 + VPC Endpoints + 核心 Managed Addon）
#
# 假设 VPC 已存在（网络团队建）。本脚本创建：
#   - EKS 集群控制面（私有 endpoint、KMS 加密可选）
#   - 集群 IAM role
#   - 核心 Managed Addon：vpc-cni / kube-proxy / eks-pod-identity-agent
#   - VPC Interface Endpoints + S3 Gateway（可通过 create_vpc_endpoints=false 关闭）
#   - CoreDNS + Metrics Server（EKS Managed Addon，需要 system 节点才能 Ready）
#   - 额外 cluster admin 的 Access Entry（可选）
#   - 额外 API ingress 规则（DX / bastion SG / CIDR）
#
# 不创建：
#   - VPC 本身
#   - 节点组（node-group/ 单独管）
#   - Cluster Autoscaler / ALB Controller 的 helm release（prerequisites/ 管 SA+IAM）
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.50"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

###############################################################################
# 集群 IAM role
###############################################################################

resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_eks" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "cluster_vpc" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSVPCResourceController"
}

###############################################################################
# CloudWatch Log Group（控制面日志）
###############################################################################

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30
}

###############################################################################
# EKS 集群
###############################################################################

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.k8s_version
  role_arn = aws_iam_role.cluster.arn

  deletion_protection       = var.enable_deletion_protection
  enabled_cluster_log_types = var.enabled_cluster_log_types

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = var.cluster_mode == "public"
    public_access_cidrs     = var.cluster_mode == "public" ? var.public_access_cidrs : null
  }

  kubernetes_network_config {
    service_ipv4_cidr = var.service_ipv4_cidr
    ip_family         = "ipv4"
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  dynamic "encryption_config" {
    for_each = var.kms_key_arn != "" ? [1] : []
    content {
      resources = ["secrets"]
      provider {
        key_arn = var.kms_key_arn
      }
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_eks,
    aws_iam_role_policy_attachment.cluster_vpc,
    aws_cloudwatch_log_group.cluster,
  ]
}

###############################################################################
# 额外 API Ingress（让 bastion / DX / VPN 能连 EKS API）
###############################################################################

resource "aws_vpc_security_group_ingress_rule" "api_extra_sg" {
  for_each = toset(var.extra_api_ingress_security_group_ids)

  security_group_id            = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  referenced_security_group_id = each.key
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Extra SG inbound to cluster API"
}

resource "aws_vpc_security_group_ingress_rule" "api_extra_cidr" {
  for_each = toset(var.extra_api_ingress_cidrs)

  security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  cidr_ipv4         = each.key
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Extra CIDR inbound to cluster API"
}

###############################################################################
# 额外 Cluster Admin（可选）
###############################################################################

resource "aws_eks_access_entry" "extra_admin" {
  for_each      = toset(var.extra_cluster_admin_role_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.key
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "extra_admin" {
  for_each      = toset(var.extra_cluster_admin_role_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.key
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on = [aws_eks_access_entry.extra_admin]
}

###############################################################################
# 核心 Managed Addon（不依赖 worker 节点即可 install）
###############################################################################

data "aws_eks_addon_version" "vpc_cni" {
  addon_name         = "vpc-cni"
  kubernetes_version = var.k8s_version
  most_recent        = true
}

data "aws_eks_addon_version" "kube_proxy" {
  addon_name         = "kube-proxy"
  kubernetes_version = var.k8s_version
  most_recent        = true
}

data "aws_eks_addon_version" "pod_identity_agent" {
  addon_name         = "eks-pod-identity-agent"
  kubernetes_version = var.k8s_version
  most_recent        = true
}

data "aws_eks_addon_version" "coredns" {
  addon_name         = "coredns"
  kubernetes_version = var.k8s_version
  most_recent        = true
}

data "aws_eks_addon_version" "metrics_server" {
  addon_name         = "metrics-server"
  kubernetes_version = var.k8s_version
  most_recent        = true
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = data.aws_eks_addon_version.vpc_cni.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  configuration_values = jsonencode({
    env = {
      AWS_VPC_K8S_CNI_EXTERNALSNAT = "false"
      WARM_ENI_TARGET              = "0"
      WARM_IP_TARGET               = "5"
      MINIMUM_IP_TARGET            = "3"
    }
  })
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  addon_version               = data.aws_eks_addon_version.kube_proxy.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = data.aws_eks_addon_version.pod_identity_agent.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  count                       = var.install_coredns ? 1 : 0
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  addon_version               = data.aws_eks_addon_version.coredns.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "metrics_server" {
  count                       = var.install_metrics_server ? 1 : 0
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "metrics-server"
  addon_version               = data.aws_eks_addon_version.metrics_server.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

###############################################################################
# VPC Endpoints（可通过 create_vpc_endpoints=false 关闭）
#
# 私有集群需要 VPC Endpoint 让节点/Pod 访问 AWS 服务。
# 如果客户已手动创建过 endpoint，设 create_vpc_endpoints=false 跳过。
###############################################################################

data "aws_vpc" "main" {
  count = var.create_vpc_endpoints ? 1 : 0
  id    = var.vpc_id
}

resource "aws_security_group" "endpoints" {
  count       = var.create_vpc_endpoints ? 1 : 0
  name        = "${var.cluster_name}-vpc-endpoints-sg"
  description = "VPC Interface Endpoints SG"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.cluster_name}-vpc-endpoints-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  count             = var.create_vpc_endpoints ? 1 : 0
  security_group_id = aws_security_group.endpoints[0].id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS from VPC"
}

resource "aws_vpc_security_group_egress_rule" "endpoints_all" {
  count             = var.create_vpc_endpoints ? 1 : 0
  security_group_id = aws_security_group.endpoints[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All egress"
}

locals {
  required_endpoint_services = ["eks", "eks-auth", "sts", "ec2"]
  full_endpoint_services = [
    "ecr.api", "ecr.dkr", "logs", "autoscaling",
    "elasticloadbalancing", "elasticfilesystem",
    "ssm", "ssmmessages", "ec2messages",
  ]
  interface_services = (
    var.create_vpc_endpoints
    ? (var.vpc_endpoints_mode == "full"
      ? concat(local.required_endpoint_services, local.full_endpoint_services)
    : local.required_endpoint_services)
    : []
  )
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_services)

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true

  tags = { Name = "${var.cluster_name}-${each.key}-endpoint" }
}

data "aws_route_tables" "private" {
  count  = var.create_vpc_endpoints ? 1 : 0
  vpc_id = var.vpc_id
  filter {
    name   = "association.subnet-id"
    values = var.private_subnet_ids
  }
}

resource "aws_vpc_endpoint" "s3_gateway" {
  count             = var.create_vpc_endpoints ? 1 : 0
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.private[0].ids

  tags = { Name = "${var.cluster_name}-s3-gateway-endpoint" }
}
