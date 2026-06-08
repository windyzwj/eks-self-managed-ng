###############################################################################
# EKS Self-Managed Node Group（支持 B300/p5 EFA 多网卡实例）
#
# 功能：
#   - 在已有 EKS 集群中创建 self-managed 节点组
#   - 通过 desired_size 扩缩容
#   - 通过 terraform taint 或 ASG detach 删除指定节点
#   - 节点通过 nodeadm 自动加入集群
#
# 使用方式：
#   创建：terraform apply
#   扩容：修改 desired_size 后 terraform apply
#   删除指定节点：
#     aws autoscaling terminate-instance-in-auto-scaling-group \
#       --instance-id i-xxx --should-decrement-desired-capacity \
#       --region <region>
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

provider "aws" {
  region = var.region
}

###############################################################################
# Variables
###############################################################################

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "cluster_name" {
  description = "已有 EKS 集群名称"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS API server endpoint"
  type        = string
}

variable "cluster_ca" {
  description = "EKS cluster CA certificate (base64)"
  type        = string
}

variable "cluster_sg_id" {
  description = "EKS cluster security group ID"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "节点子网 ID 列表（CB/ODCR 场景通常只填一个 AZ 的子网）"
  type        = list(string)
}

variable "instance_type" {
  description = "实例类型"
  type        = string
  default     = "p6-b300.48xlarge"
}

variable "desired_size" {
  description = "期望节点数（修改后 terraform apply 即可扩缩容）"
  type        = number
  default     = 1
}

variable "min_size" {
  type    = number
  default = 0
}

variable "max_size" {
  type    = number
  default = 4
}

variable "key_name" {
  description = "EC2 Key Pair（可选，留空则只能通过 SSM 登录）"
  type        = string
  default     = ""
}

variable "capacity_reservation_id" {
  description = "Capacity Reservation ID（CB/ODCR），留空 = 不指定"
  type        = string
  default     = ""
}

variable "placement_group_name" {
  description = "Placement Group 名称（CB/ODCR 购买时绑定的 PG）"
  type        = string
  default     = ""
}

variable "purchase_mode" {
  description = "购买模式：on_demand / spot / odcr / capacity_block"
  type        = string
  default     = "on_demand"
  validation {
    condition     = contains(["on_demand", "spot", "odcr", "capacity_block"], var.purchase_mode)
    error_message = "purchase_mode 必须是 on_demand / spot / odcr / capacity_block"
  }
}

variable "efa_card_count_override" {
  description = "手动指定 EFA-only 网卡数。-1 = 按 instance_type 自动判断"
  type        = number
  default     = -1
}

variable "install_efa_userspace" {
  description = "是否在 user-data 里安装 EFA userspace（libfabric-aws）。纯私网无 NAT 应设 false"
  type        = bool
  default     = true
}

variable "efa_installer_version" {
  description = "EFA Installer 版本。B300 至少需要 1.47+"
  type        = string
  default     = "1.48.0"
}

variable "root_volume_size" {
  type    = number
  default = 300
}

variable "name_prefix" {
  description = "资源名前缀"
  type        = string
  default     = "eks-gpu-ng"
}

variable "eks_version" {
  description = "EKS 版本号，用于查询 AMI"
  type        = string
  default     = "1.35"
}

variable "node_labels" {
  description = "K8S 节点标签"
  type        = map(string)
  default = {
    "node.kubernetes.io/instance-type" = "p6-b300.48xlarge"
    "nvidia.com/gpu.present"           = "true"
  }
}

variable "node_taints" {
  description = "K8S 节点 taints（格式: key=value:effect）"
  type        = list(string)
  default     = ["nvidia.com/gpu=:NoSchedule"]
}

variable "additional_sg_ids" {
  description = "额外附加的 Security Group IDs"
  type        = list(string)
  default     = []
}

variable "existing_node_sg_id" {
  description = "复用已有的节点 SG ID。留空则新建"
  type        = string
  default     = ""
}

variable "existing_node_role_arn" {
  description = "复用已有的节点 IAM Role ARN。留空则新建"
  type        = string
  default     = ""
}

variable "existing_instance_profile_name" {
  description = "复用已有的 Instance Profile 名称。留空则新建（需与 existing_node_role_arn 配套）"
  type        = string
  default     = ""
}

###############################################################################
# Data Sources
###############################################################################

data "aws_ssm_parameter" "eks_nvidia_ami" {
  name = "/aws/service/eks/optimized-ami/${var.eks_version}/amazon-linux-2023/x86_64/nvidia/recommended/image_id"
}

###############################################################################
# Locals
###############################################################################

locals {
  ami_id = nonsensitive(data.aws_ssm_parameter.eks_nvidia_ami.value)

  efa_card_count_auto = (
    contains(["p6-b300.48xlarge", "p6-b200.48xlarge"], var.instance_type) ? 16 :
    contains(["p5.48xlarge", "p5en.48xlarge"], var.instance_type) ? 32 :
    0
  )
  efa_card_count  = var.efa_card_count_override >= 0 ? var.efa_card_count_override : local.efa_card_count_auto
  total_nic_count = 1 + local.efa_card_count

  network_interfaces_config = [
    for i in range(local.total_nic_count) : {
      network_card_index = i
      interface_type     = i == 0 ? null : "efa-only"
      device_index       = 0
    }
  ]

  # 如果传入已有 SG 则复用，否则取新建的
  node_sg_id = var.existing_node_sg_id != "" ? var.existing_node_sg_id : aws_security_group.node[0].id
  all_sg_ids = concat([local.node_sg_id, var.cluster_sg_id], var.additional_sg_ids)

  # 如果传入已有 Role 则复用，否则取新建的
  node_role_arn  = var.existing_node_role_arn != "" ? var.existing_node_role_arn : aws_iam_role.node[0].arn
  node_role_name = var.existing_node_role_arn != "" ? regex("[^/]+$", var.existing_node_role_arn) : aws_iam_role.node[0].name

  # nodeadm 配置（EKS 1.35+ 推荐方式）
  nodeadm_config = <<-YAML
    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      cluster:
        name: ${var.cluster_name}
        apiServerEndpoint: ${var.cluster_endpoint}
        certificateAuthority: ${var.cluster_ca}
        cidr: 10.200.0.0/16
      kubelet:
        config:
          maxPods: 250
        flags:
          - --node-labels=${join(",", [for k, v in var.node_labels : "${k}=${v}"])}
          %{if length(var.node_taints) > 0}- --register-with-taints=${join(",", var.node_taints)}%{endif}
  YAML
}

###############################################################################
# Security Group
###############################################################################

resource "aws_security_group" "node" {
  count       = var.existing_node_sg_id == "" ? 1 : 0
  name        = "${var.name_prefix}-node-sg"
  description = "Self-managed GPU node SG"
  vpc_id      = var.vpc_id

  # 集群 SG 入向全通
  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [var.cluster_sg_id]
  }

  # EFA self-referencing
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                                        = "${var.name_prefix}-node-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

###############################################################################
# IAM
###############################################################################

resource "aws_iam_role" "node" {
  count = var.existing_node_role_arn == "" ? 1 : 0
  name  = "${var.name_prefix}-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = var.existing_node_role_arn == "" ? toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]) : toset([])
  role       = local.node_role_name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "node" {
  count = var.existing_node_role_arn == "" ? 1 : 0
  name  = "${var.name_prefix}-node-profile"
  role  = aws_iam_role.node[0].name
}

###############################################################################
# Launch Template
###############################################################################

resource "aws_launch_template" "node" {
  name_prefix   = "${var.name_prefix}-lt-"
  image_id      = local.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name != "" ? var.key_name : null

  iam_instance_profile {
    name = var.existing_node_role_arn == "" ? aws_iam_instance_profile.node[0].name : var.existing_instance_profile_name
  }

  # 多网卡声明
  dynamic "network_interfaces" {
    for_each = local.network_interfaces_config
    content {
      device_index          = network_interfaces.value.device_index
      network_card_index    = network_interfaces.value.network_card_index
      interface_type        = network_interfaces.value.interface_type
      security_groups       = local.all_sg_ids
      delete_on_termination = true
      # subnet_id 由 ASG 指定，不在 LT 里写（多 AZ 场景）
    }
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size
      iops                  = 3000
      throughput            = 250
      delete_on_termination = true
      encrypted             = true
    }
  }

  # 额外数据盘（containerd 存储）
  block_device_mappings {
    device_name = "/dev/xvdb"
    ebs {
      volume_type           = "gp3"
      volume_size           = 100
      iops                  = 3000
      throughput            = 125
      delete_on_termination = true
      encrypted             = true
    }
  }

  user_data = base64encode(local.user_data)

  # Spot
  dynamic "instance_market_options" {
    for_each = var.purchase_mode == "spot" ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "one-time"
        instance_interruption_behavior = "terminate"
      }
    }
  }

  # CB / ODCR
  dynamic "capacity_reservation_specification" {
    for_each = contains(["odcr", "capacity_block"], var.purchase_mode) ? [1] : []
    content {
      capacity_reservation_preference = "none"
      capacity_reservation_target {
        capacity_reservation_id = var.capacity_reservation_id
      }
    }
  }

  # Placement Group
  dynamic "placement" {
    for_each = var.placement_group_name != "" ? [1] : []
    content {
      group_name = var.placement_group_name
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name                                        = "${var.name_prefix}-node"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
  }

  tag_specifications {
    resource_type = "network-interface"
    tags = { Name = "${var.name_prefix}-eni" }
  }

  tag_specifications {
    resource_type = "volume"
    tags = { Name = "${var.name_prefix}-volume" }
  }

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Auto Scaling Group
###############################################################################

resource "aws_autoscaling_group" "node" {
  name                = "${var.name_prefix}-asg"
  desired_capacity    = var.desired_size
  min_size            = var.min_size
  max_size            = var.max_size
  vpc_zone_identifier = var.subnet_ids

  launch_template {
    id      = aws_launch_template.node.id
    version = "$Latest"
  }

  # 实例刷新（LT 变更时滚动替换节点）
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-node"
    propagate_at_launch = true
  }

  tag {
    key                 = "kubernetes.io/cluster/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }

  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = true
  }

  tag {
    key                 = "k8s.io/cluster-autoscaler/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }

  lifecycle {
    # desired_size 变更不触发替换，允许外部（CA）调整
    ignore_changes = []
  }
}

###############################################################################
# User Data（nodeadm 加入集群 + EFA userspace）
###############################################################################

locals {
  _efa_install_block = <<-EFA
    # EFA userspace (libfabric-aws + openmpi5-aws)
    if [ ! -x /opt/amazon/efa/bin/fi_info ]; then
      EFA_TARBALL="aws-efa-installer-${var.efa_installer_version}.tar.gz"
      echo "=== Installing EFA userspace ($EFA_TARBALL) ==="
      ( cd /tmp && \
        curl -fsSLO "https://efa-installer.amazonaws.com/$EFA_TARBALL" && \
        tar -xf "$EFA_TARBALL" && \
        cd aws-efa-installer && \
        ./efa_installer.sh -y --skip-kmod 2>&1 | tail -30 ) || \
        echo "WARN: efa_installer failed"
    fi
  EFA

  efa_install_script = var.install_efa_userspace ? local._efa_install_block : "echo 'EFA userspace install skipped'"

  user_data = <<-EOT
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="BOUNDARY"

    --BOUNDARY
    Content-Type: application/node.eks.aws

    ${local.nodeadm_config}
    --BOUNDARY
    Content-Type: text/x-shellscript; charset="us-ascii"

    #!/bin/bash
    set -e
    exec > >(tee /var/log/user-data-custom.log) 2>&1

    ${local.efa_install_script}

    echo "=== Custom user-data done $(date) ==="
    --BOUNDARY--
  EOT
}

###############################################################################
# Outputs
###############################################################################

output "asg_name" {
  value = aws_autoscaling_group.node.name
}

output "launch_template_id" {
  value = aws_launch_template.node.id
}

output "node_role_arn" {
  value = local.node_role_arn
}

output "node_sg_id" {
  value = local.node_sg_id
}

output "instance_profile_name" {
  value = var.existing_node_role_arn == "" ? aws_iam_instance_profile.node[0].name : var.existing_instance_profile_name
}

output "usage" {
  value = <<-EOT

  =============================================
   Self-Managed Node Group: ${var.name_prefix}
  =============================================
   集群: ${var.cluster_name}
   实例类型: ${var.instance_type}
   网卡: ${local.total_nic_count} (1 primary + ${local.efa_card_count} EFA-only)
   ASG: ${aws_autoscaling_group.node.name}

   ⚠️  首次创建后需要在 EKS 的 aws-auth ConfigMap 里添加节点 Role：
     kubectl edit configmap aws-auth -n kube-system
     # 添加：
     # - rolearn: ${local.node_role_arn}
     #   username: system:node:{{EC2PrivateDNSName}}
     #   groups:
     #     - system:bootstrappers
     #     - system:nodes

   扩容：修改 desired_size 后 terraform apply
   缩容：同上（ASG 会按策略终止节点）

   删除指定节点：
     # 1. 先 drain
     kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
     # 2. 从 ASG 中移除并终止
     aws autoscaling terminate-instance-in-auto-scaling-group \
       --instance-id i-xxx --should-decrement-desired-capacity \
       --region ${var.region}

   销毁整个节点组：
     terraform destroy

  =============================================
  EOT
}
