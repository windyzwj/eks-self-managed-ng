###############################################################################
# Part 1 — GPU node prerequisites (platform side, one-time)
#
# Creates the cluster-level singletons that ALL self-managed GPU node groups
# share. Run this ONCE per cluster. The node-group/ stack (Part 2) consumes
# the outputs here and can be applied many times (one per ASG).
#
# What this creates:
#   - GPU node IAM role + 4 EKS managed policies + nodeadm inline policy
#   - Instance profile (self-managed ASGs launch from a Launch Template, which
#     requires an instance profile — managed NGs get one implicitly)
#   - EKS Access Entry (EC2_LINUX) so nodes using this role can join the
#     cluster under API auth. Works alongside aws-auth on API_AND_CONFIG_MAP
#     clusters; see README for the aws-auth fallback.
#   - GPU security group with EFA self-allow (required for cross-node NCCL)
#   - Cluster SG ingress from the node SG (managed NGs got this auto from EKS)
#
# These are deliberately NOT in the node-group stack because:
#   - The IAM role / access entry are cluster-level singletons. One per
#     cluster, shared by every GPU ASG. Creating them per-ASG would produce
#     duplicate roles and conflicting access entries.
#   - The GPU SG must be shared so EFA traffic flows across ASGs (NCCL
#     all-reduce spans nodes in different ASGs).
#   - These touch iam:* / eks:CreateAccessEntry — typically platform/security
#     team permissions, not the app team that scales node groups.
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
# IAM role for GPU nodes (cluster-wide singleton)
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

# nodeadm (EKS 1.34+) needs ec2:DescribeInstances / DescribeTags to
# self-discover instance metadata during bootstrap.
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
# EKS Access Entry — register the node role with the cluster (API auth)
#
# On an API_AND_CONFIG_MAP cluster both this and aws-auth work; we default to
# Access Entry because it's TF-managed, auditable, and the direction AWS is
# moving (aws-auth is being phased out). Set create_access_entry=false if your
# cluster is CONFIG_MAP-only or you manage node auth via aws-auth — then add
# the role to aws-auth manually (see README).
###############################################################################

resource "aws_eks_access_entry" "gpu_node" {
  count = var.create_access_entry ? 1 : 0

  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.gpu_node.arn
  type          = "EC2_LINUX"
}

###############################################################################
# GPU security group (cluster-wide singleton, EFA self-allow)
#
# Shared by every GPU ASG so EFA / NCCL traffic flows across nodes regardless
# of which ASG they belong to. The self-referencing all-traffic rules are
# required by AWS for EFA (libfabric) cross-node communication.
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

# EFA self-allow (all protocols within the SG) — required for NCCL.
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

# General egress (image pull via NAT / VPC endpoints, EFA installer, etc.)
resource "aws_vpc_security_group_egress_rule" "gpu_all" {
  security_group_id = aws_security_group.gpu_node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all egress"
}

# Cluster SG must accept traffic from the node SG (kubelet -> API server,
# control plane -> kubelet). Managed NGs got this automatically from EKS;
# self-managed must declare it.
resource "aws_vpc_security_group_ingress_rule" "cluster_from_node" {
  security_group_id            = var.cluster_security_group_id
  referenced_security_group_id = aws_security_group.gpu_node.id
  ip_protocol                  = "-1"
  description                  = "Self-managed GPU nodes to cluster API/control plane"
}
