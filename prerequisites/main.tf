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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
  }
}

provider "aws" {
  region = var.region
}

# kubernetes provider 用于创建 ServiceAccount（CA / ALB 的 Pod Identity 前置）。
# 如果 install_cluster_autoscaler_prereqs 和 install_alb_controller_prereqs 都为
# false，provider 配了但不会真正调用（无 kubernetes_ resource 创建）。
provider "kubernetes" {
  host                   = var.cluster_endpoint
  cluster_ca_certificate = base64decode(var.cluster_ca)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
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

###############################################################################
# Cluster Autoscaler — SA + IAM role + Pod Identity Association
#
# helm install 放在 MANUAL_PLUGINS.md 手动装（需要 system node 跑 pod）。
# 这里只建 SA + IAM（不依赖 node 存在）。
###############################################################################

resource "aws_iam_role" "cluster_autoscaler" {
  count = var.install_cluster_autoscaler_prereqs ? 1 : 0
  name  = "${var.name_prefix}-cluster-autoscaler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  count = var.install_cluster_autoscaler_prereqs ? 1 : 0
  name  = "ClusterAutoscalerPolicy"
  role  = aws_iam_role.cluster_autoscaler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
          }
        }
      },
    ]
  })
}

resource "kubernetes_service_account_v1" "cluster_autoscaler" {
  count = var.install_cluster_autoscaler_prereqs ? 1 : 0
  metadata {
    name      = "cluster-autoscaler"
    namespace = "kube-system"
    labels    = { "app.kubernetes.io/name" = "cluster-autoscaler" }
  }
}

resource "aws_eks_pod_identity_association" "cluster_autoscaler" {
  count           = var.install_cluster_autoscaler_prereqs ? 1 : 0
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "cluster-autoscaler"
  role_arn        = aws_iam_role.cluster_autoscaler[0].arn
  depends_on      = [kubernetes_service_account_v1.cluster_autoscaler]
}

###############################################################################
# ALB Controller — SA + IAM policy/role + Pod Identity Association
#
# helm install 放在 MANUAL_PLUGINS.md 手动装。
###############################################################################

resource "aws_iam_role" "alb_controller" {
  count = var.install_alb_controller_prereqs ? 1 : 0
  name  = "${var.name_prefix}-alb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_policy" "alb_controller" {
  count  = var.install_alb_controller_prereqs ? 1 : 0
  name   = "${var.name_prefix}-alb-controller-policy"
  policy = file("${path.module}/alb-controller-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  count      = var.install_alb_controller_prereqs ? 1 : 0
  role       = aws_iam_role.alb_controller[0].name
  policy_arn = aws_iam_policy.alb_controller[0].arn
}

resource "kubernetes_service_account_v1" "alb_controller" {
  count = var.install_alb_controller_prereqs ? 1 : 0
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
      "app.kubernetes.io/component" = "controller"
    }
  }
}

resource "aws_eks_pod_identity_association" "alb_controller" {
  count           = var.install_alb_controller_prereqs ? 1 : 0
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.alb_controller[0].arn
  depends_on      = [kubernetes_service_account_v1.alb_controller]
}
