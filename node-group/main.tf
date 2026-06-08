###############################################################################
# Part 2 — Self-managed GPU node group (customer side, repeatable)
#
# Creates ONE self-managed node group: Launch Template (with EFA multi-NIC
# layout) + ASG (no self-healing) that joins an existing EKS cluster via
# nodeadm. Apply once per node group; use multiple copies / a wrapper module
# with for_each for several pools (e.g. 3 ODCRs).
#
# Consumes the cluster-level singletons created by ../prerequisites:
#   existing_node_role_arn, existing_instance_profile_name, existing_node_sg_id
#
# Lifecycle model (NO self-healing — deliberate):
#   - suspended_processes = [ReplaceUnhealthy, AZRebalance] : the ASG never
#     terminates+replaces an instance on its own. Instance IDs are stable.
#   - health_check_type = "EC2" : an ALB target marked unhealthy never
#     triggers an ASG terminate.
#   - no instance_refresh : changing the LT does NOT roll instances.
#   - lifecycle ignore_changes=[desired_capacity] : Cluster Autoscaler owns
#     desired; terraform won't drift it back.
#
# Scale up:   raise desired_size (or let your CA do it) + terraform apply
# Retire one: aws autoscaling terminate-instance-in-auto-scaling-group \
#               --instance-id i-xxx --should-decrement-desired-capacity
# Upgrade AMI/LT: update LT, then drain + terminate each node yourself
#                 (the ASG will NOT roll them automatically by design).
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

###############################################################################
# AMI lookup (EKS-optimized AL2023 NVIDIA)
###############################################################################

data "aws_ssm_parameter" "gpu_ami" {
  count = var.custom_ami_id == "" ? 1 : 0
  name = (
    var.gpu_ami_release_version == "" ?
    "/aws/service/eks/optimized-ami/${var.eks_version}/amazon-linux-2023/x86_64/nvidia/recommended/image_id" :
    "/aws/service/eks/optimized-ami/${var.eks_version}/amazon-linux-2023/x86_64/nvidia/amazon-eks-node-al2023-x86_64-nvidia-${var.eks_version}-${var.gpu_ami_release_version}/image_id"
  )
}

###############################################################################
# EFA multi-NIC layout (per instance type)
#
# efa_only_count : number of EFA-only NICs on indices 1..N (NIC 0 is primary).
# primary_efa    : whether NIC 0 carries EFA (efa) or is plain ENA (interface).
#   p6-b300 is special: NIC 0 = ENA only, NIC 1..16 = EFA-only (17 total).
# Unknown types fall back to a single plain NIC (no EFA).
###############################################################################

locals {
  efa_layout_default = { efa_only_count = 0, primary_efa = false }
  efa_layout = {
    "p5.48xlarge"      = { efa_only_count = 31, primary_efa = true }
    "p5en.48xlarge"    = { efa_only_count = 15, primary_efa = true }
    "p6-b200.48xlarge" = { efa_only_count = 7, primary_efa = true }
    "p6-b300.48xlarge" = { efa_only_count = 16, primary_efa = false } # NIC 0 = ENA only

    "g6e.8xlarge"  = { efa_only_count = 0, primary_efa = true }
    "g6e.12xlarge" = { efa_only_count = 0, primary_efa = true }
    "g6e.16xlarge" = { efa_only_count = 0, primary_efa = true }
    "g6e.24xlarge" = { efa_only_count = 1, primary_efa = true }
    "g6e.48xlarge" = { efa_only_count = 3, primary_efa = true }

    "g7e.8xlarge"  = { efa_only_count = 0, primary_efa = true }
    "g7e.12xlarge" = { efa_only_count = 0, primary_efa = true }
    "g7e.24xlarge" = { efa_only_count = 1, primary_efa = true }
    "g7e.48xlarge" = { efa_only_count = 3, primary_efa = true }
  }

  layout                 = lookup(local.efa_layout, var.instance_type, local.efa_layout_default)
  efa_only_count         = var.efa_card_count_override >= 0 ? var.efa_card_count_override : local.layout.efa_only_count
  primary_interface_type = local.layout.primary_efa ? "efa" : "interface"
  total_nic_count        = 1 + local.efa_only_count
  efa_resource_count     = local.efa_only_count + (local.layout.primary_efa ? 1 : 0)

  ami_id = var.custom_ami_id != "" ? var.custom_ami_id : nonsensitive(data.aws_ssm_parameter.gpu_ami[0].value)

  # GPU count per instance type — used for CA scale-from-zero resource hint.
  gpu_count = lookup({
    "p5.48xlarge"      = 8
    "p5en.48xlarge"    = 8
    "p6-b200.48xlarge" = 8
    "p6-b300.48xlarge" = 8
    "g6e.8xlarge"      = 1
    "g6e.12xlarge"     = 4
    "g6e.16xlarge"     = 1
    "g6e.24xlarge"     = 4
    "g6e.48xlarge"     = 8
    "g7e.8xlarge"      = 1
    "g7e.12xlarge"     = 4
    "g7e.24xlarge"     = 4
    "g7e.48xlarge"     = 8
  }, var.instance_type, 0)

  # K8s node labels (workload-type=gpu style, aligned with the device-plugin
  # nodeSelector documented in ../prerequisites/MANUAL_PLUGINS.md).
  base_node_labels = {
    "workload-type"     = "gpu"
    "gpu-instance-type" = var.instance_type
    "purchase-option"   = var.purchase_mode
  }
  node_labels     = merge(local.base_node_labels, var.extra_node_labels)
  node_labels_csv = join(",", [for k, v in local.node_labels : "${k}=${v}"])
  node_taints_csv = join(",", var.node_taints)

  all_sg_ids = concat([var.existing_node_sg_id, var.cluster_security_group_id], var.additional_sg_ids)

  userdata = templatefile("${path.module}/templates/userdata.sh.tpl", {
    cluster_name                 = var.cluster_name
    cluster_endpoint             = var.cluster_endpoint
    cluster_ca                   = var.cluster_ca
    service_ipv4_cidr            = var.service_ipv4_cidr
    node_management              = "self_managed"
    extra_node_labels            = local.node_labels_csv
    node_taints                  = local.node_taints_csv
    enable_local_lvm             = var.enable_local_lvm
    local_lvm_vg_name            = var.local_lvm_vg_name
    local_lvm_lv_name            = var.local_lvm_lv_name
    local_lvm_mount              = var.local_lvm_mount
    local_lvm_fs                 = var.local_lvm_fs
    local_lvm_stripe_kb          = var.local_lvm_stripe_kb
    install_efa_userspace        = var.install_efa_userspace
    efa_installer_version        = var.efa_installer_version
    ebs_data_disk_detect_snippet = file("${path.module}/templates/detect-ebs-disk.sh")
  })

  # ASG tags: CA discovery + scale-from-zero hints (so an external Cluster
  # Autoscaler can find this ASG and reason about pod fit before launch).
  ca_tags = merge(
    {
      "Name"                                                             = "${var.name_prefix}-node"
      "kubernetes.io/cluster/${var.cluster_name}"                        = "owned"
      "k8s.io/cluster-autoscaler/enabled"                                = "true"
      "k8s.io/cluster-autoscaler/${var.cluster_name}"                    = "owned"
      "k8s.io/cluster-autoscaler/node-template/label/workload-type"      = "gpu"
      "k8s.io/cluster-autoscaler/node-template/label/gpu-instance-type"  = var.instance_type
      "k8s.io/cluster-autoscaler/node-template/label/purchase-option"    = var.purchase_mode
      "k8s.io/cluster-autoscaler/node-template/taint/nvidia.com/gpu"     = "true:NoSchedule"
      "k8s.io/cluster-autoscaler/node-template/resources/nvidia.com/gpu" = tostring(local.gpu_count)
    },
    local.efa_resource_count > 0 ? {
      "k8s.io/cluster-autoscaler/node-template/resources/vpc.amazonaws.com/efa" = tostring(local.efa_resource_count)
    } : {},
    var.extra_asg_tags,
  )
}

###############################################################################
# Launch Template (EFA multi-NIC + LVM userdata + 2 EBS volumes)
###############################################################################

resource "aws_launch_template" "node" {
  name_prefix   = "${var.name_prefix}-lt-"
  image_id      = local.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name != "" ? var.key_name : null

  iam_instance_profile {
    name = var.existing_instance_profile_name
  }

  user_data = base64encode(local.userdata)

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  # Primary NIC (NetworkCardIndex=0). interface=plain ENA (p6-b300) or
  # efa=ENA+EFA combined (p5/p6-b200/g6e/g7e).
  network_interfaces {
    network_card_index    = 0
    device_index          = 0
    interface_type        = local.primary_interface_type
    delete_on_termination = true
    security_groups       = local.all_sg_ids
  }

  # EFA-only NICs (NetworkCardIndex 1..efa_only_count). Each is its own
  # physical network card; device_index stays 0 on each.
  dynamic "network_interfaces" {
    for_each = range(1, local.efa_only_count + 1)
    content {
      network_card_index    = network_interfaces.value
      device_index          = 0
      interface_type        = "efa-only"
      delete_on_termination = true
      security_groups       = local.all_sg_ids
    }
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 250
      encrypted             = true
      delete_on_termination = true
    }
  }

  block_device_mappings {
    device_name = "/dev/xvdb"
    ebs {
      volume_size           = var.data_volume_size
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      encrypted             = true
      delete_on_termination = true
    }
  }

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

  dynamic "capacity_reservation_specification" {
    for_each = contains(["odcr", "capacity_block"], var.purchase_mode) ? [1] : []
    content {
      capacity_reservation_target {
        capacity_reservation_id = var.capacity_reservation_id
      }
    }
  }

  dynamic "instance_market_options" {
    for_each = var.purchase_mode == "capacity_block" ? [1] : []
    content {
      market_type = "capacity-block"
    }
  }

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
    tags          = { Name = "${var.name_prefix}-eni" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${var.name_prefix}-volume" }
  }

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = !(var.purchase_mode == "capacity_block" && var.capacity_reservation_id == "")
      error_message = "purchase_mode=capacity_block requires capacity_reservation_id."
    }
    precondition {
      condition     = !(var.purchase_mode == "odcr" && var.capacity_reservation_id == "")
      error_message = "purchase_mode=odcr requires capacity_reservation_id."
    }
  }
}

###############################################################################
# Auto Scaling Group (NO self-healing)
###############################################################################

resource "aws_autoscaling_group" "node" {
  name                = "${var.name_prefix}-asg"
  desired_capacity    = var.desired_size
  min_size            = var.min_size
  max_size            = var.max_size
  vpc_zone_identifier = var.subnet_ids

  # No self-healing: ASG never replaces an instance or AZ-rebalances on its
  # own. Instance IDs stay stable until you explicitly retire them.
  suspended_processes = var.asg_suspended_processes

  # Don't let an ALB target marked unhealthy trigger an ASG terminate.
  health_check_type         = "EC2"
  health_check_grace_period = 600

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  dynamic "tag" {
    for_each = local.ca_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  # CA owns desired_capacity at runtime; don't let terraform drift it back.
  # No instance_refresh block: LT changes do NOT roll instances (by design).
  lifecycle {
    ignore_changes = [desired_capacity]
  }
}
