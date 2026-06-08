###############################################################################
# Part 1 — GPU 节点前置资源（平台侧，每集群一次性）
#
# 创建所有 self-managed GPU 节点组共享的集群级单例资源。每集群只跑一次。
# node-group/ 脚本（Part 2）消费本文件的 output，可多次 apply（每个 ASG 一次）。
#
# 创建的内容：
#   - GPU 节点 IAM role + 4 个 EKS managed policy + nodeadm 内联 policy
#   - Instance profile（self-managed ASG 从 LT 起实例时必须有——Managed NG 隐式创建）
#   - EKS Access Entry（EC2_LINUX）让使用此 role 的节点能通过 API auth 加入集群
#     在 API_AND_CONFIG_MAP 集群上与 aws-auth 共存；见 README 的 aws-auth 备选方案
#   - GPU 安全组 + EFA 自通规则（跨节点 NCCL 必须）
#   - Cluster SG 入向规则，来自节点 SG（Managed NG 由 EKS 自动加，self-managed 需显式声明）
#
# 为什么这些不在 node-group 里：
#   - IAM role / access entry 是集群级单例——一个集群一份，所有 GPU ASG 共享
#     如果每个 ASG 各建一份，会产生重复 role 和冲突的 access entry
#   - GPU SG 必须共享——EFA 流量要求所有 GPU 节点在同一 SG（跨 ASG 也是）
#   - 这些操作涉及 iam:* / eks:CreateAccessEntry —— 通常是平台/安全团队权限
#     不应下放给扩缩节点组的应用团队
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.50"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_partition" "current" {}

###############################################################################
# GPU 节点 IAM role（集群级单例，所有 GPU ASG 共享）
###############################################################################

resource "aws_iam_role" "gpu_node" {
  name = "${var.name_prefix}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "gpu_node" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.gpu_node.name
  policy_arn = each.value
}

# nodeadm（EKS 1.34+）启动时需要 ec2:DescribeInstances / DescribeTags
# 用于自动发现实例元数据。
resource "aws_iam_role_policy" "gpu_nodeadm" {
  name = "NodeadmDescribeInstances"
  role = aws_iam_role.gpu_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances", "ec2:DescribeTags"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "gpu_node" {
  name = "${var.name_prefix}-node-profile"
  role = aws_iam_role.gpu_node.name
  tags = var.tags
}

###############################################################################
# EKS Access Entry —— 把节点 role 注册进集群（API 认证）
#
# API_AND_CONFIG_MAP 集群上 Access Entry 和 aws-auth 都生效；默认使用 Access Entry
# 因为它可 TF 管理、可审计，且是 AWS 推荐方向（aws-auth 逐步废弃）。
# 如果集群是 CONFIG_MAP-only 或你选择用 aws-auth，设 create_access_entry=false
# 然后手动把 role 加进 aws-auth（见 README）。
###############################################################################

resource "aws_eks_access_entry" "gpu_node" {
  count = var.create_access_entry ? 1 : 0

  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.gpu_node.arn
  type          = "EC2_LINUX"
}

###############################################################################
# GPU 安全组（集群级单例，EFA 自通）
#
# 所有 GPU ASG 共享——EFA/NCCL 流量必须跨节点互通，不管节点属于哪个 ASG。
# 自引用全协议规则是 AWS 对 EFA（libfabric）跨节点通信的硬性要求。
###############################################################################

resource "aws_security_group" "gpu_node" {
  name        = "${var.name_prefix}-node-sg"
  description = "Self-managed GPU node SG (shared, EFA self-allow)"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name                                        = "${var.name_prefix}-node-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

# EFA 自通（SG 内全协议互通）—— NCCL 必须。
resource "aws_vpc_security_group_ingress_rule" "gpu_self" {
  security_group_id            = aws_security_group.gpu_node.id
  referenced_security_group_id = aws_security_group.gpu_node.id
  ip_protocol                  = "-1"
  description                  = "EFA self-allow"
}

resource "aws_vpc_security_group_egress_rule" "gpu_self" {
  security_group_id            = aws_security_group.gpu_node.id
  referenced_security_group_id = aws_security_group.gpu_node.id
  ip_protocol                  = "-1"
  description                  = "EFA self-egress"
}

# 通用出向（镜像拉取走 NAT / VPC endpoint，EFA installer 等）
resource "aws_vpc_security_group_egress_rule" "gpu_all" {
  security_group_id = aws_security_group.gpu_node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all egress"
}

# Cluster SG 必须接受节点 SG 的流量（kubelet -> API server，控制面 -> kubelet）。
# Managed NG 由 EKS 自动加；self-managed 必须显式声明。
resource "aws_vpc_security_group_ingress_rule" "cluster_from_node" {
  security_group_id            = var.cluster_security_group_id
  referenced_security_group_id = aws_security_group.gpu_node.id
  ip_protocol                  = "-1"
  description                  = "Self-managed GPU nodes to cluster API/control plane"
}
