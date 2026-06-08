###############################################################################
# Cluster context (from `aws eks describe-cluster` / Part 1 outputs)
###############################################################################

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "cluster_name" {
  description = "Existing EKS cluster name."
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS API server endpoint (https://...)."
  type        = string
}

variable "cluster_ca" {
  description = "EKS cluster CA certificate, base64 (the raw describe-cluster value, NOT decoded)."
  type        = string
}

variable "cluster_security_group_id" {
  description = "EKS cluster security group ID (control plane <-> node)."
  type        = string
}

variable "service_ipv4_cidr" {
  description = <<-EOT
    The cluster's Kubernetes service CIDR. nodeadm needs this to configure
    kubelet. Find it via:
      aws eks describe-cluster --name <cluster> \
        --query 'cluster.kubernetesNetworkConfig.serviceIpv4Cidr' --output text
    EKS default is 172.20.0.0/16. Set to your cluster's actual value.
  EOT
  type        = string
  default     = "172.20.0.0/16"
}

variable "vpc_id" {
  description = "VPC ID (used for tagging / reference)."
  type        = string
  default     = ""
}

###############################################################################
# Prerequisites (Part 1 outputs)
###############################################################################

variable "existing_node_role_arn" {
  description = "GPU node IAM role ARN from the prerequisites stack (gpu_node_role_arn)."
  type        = string
}

variable "existing_instance_profile_name" {
  description = "Instance profile name from the prerequisites stack (gpu_instance_profile_name)."
  type        = string
}

variable "existing_node_sg_id" {
  description = "Shared GPU node SG ID from the prerequisites stack (gpu_node_sg_id)."
  type        = string
}

variable "additional_sg_ids" {
  description = "Extra security groups to attach to every NIC."
  type        = list(string)
  default     = []
}

###############################################################################
# Node group shape
###############################################################################

variable "name_prefix" {
  description = "Prefix for this node group's resources. Use a unique value per pool (e.g. eks-gpu-b300-odcr1)."
  type        = string
  default     = "eks-gpu-ng"
}

variable "instance_type" {
  type    = string
  default = "p6-b300.48xlarge"
}

variable "desired_size" {
  description = "Desired node count. Cluster Autoscaler may change this at runtime (terraform ignores drift)."
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

variable "subnet_ids" {
  description = "Subnets for the ASG. For ODCR/CB pin to the single AZ of the reservation."
  type        = list(string)
}

variable "key_name" {
  description = "EC2 Key Pair (optional; empty = SSM-only access)."
  type        = string
  default     = ""
}

###############################################################################
# AMI
###############################################################################

variable "eks_version" {
  description = "EKS version, used to resolve the EKS-NVIDIA AMI via SSM."
  type        = string
  default     = "1.35"
}

variable "gpu_ami_release_version" {
  description = "Pin a specific EKS-NVIDIA AMI release (e.g. v20260527). Empty = SSM 'recommended'. Ignored if custom_ami_id is set."
  type        = string
  default     = ""
}

variable "custom_ami_id" {
  description = "Override with a fully-specified AMI ID (must derive from the EKS-NVIDIA base). Empty = SSM lookup."
  type        = string
  default     = ""

  validation {
    condition     = var.custom_ami_id == "" || can(regex("^ami-[0-9a-f]+$", var.custom_ami_id))
    error_message = "custom_ami_id must be empty or a valid AMI ID (^ami-[0-9a-f]+$)."
  }
}

###############################################################################
# Pricing / capacity
###############################################################################

variable "purchase_mode" {
  description = "on_demand / spot / odcr / capacity_block."
  type        = string
  default     = "on_demand"
  validation {
    condition     = contains(["on_demand", "spot", "odcr", "capacity_block"], var.purchase_mode)
    error_message = "purchase_mode must be on_demand / spot / odcr / capacity_block."
  }
}

variable "capacity_reservation_id" {
  description = "Capacity Reservation ID — required when purchase_mode is odcr or capacity_block."
  type        = string
  default     = ""
}

variable "placement_group_name" {
  description = "Cluster placement group name (optional; recommended for single-AZ multi-node NCCL)."
  type        = string
  default     = ""
}

###############################################################################
# EFA
###############################################################################

variable "efa_card_count_override" {
  description = "Force the number of EFA-only NICs. -1 = auto from instance_type layout table."
  type        = number
  default     = -1
}

variable "install_efa_userspace" {
  description = "Install EFA userspace (libfabric-aws) in user-data at first boot. Default true (nodes have NAT). Set false for fully air-gapped nodes using an AMI with libfabric pre-baked."
  type        = bool
  default     = true
}

variable "efa_installer_version" {
  description = "aws-efa-installer version. B300 needs 1.47+."
  type        = string
  default     = "1.48.0"
}

###############################################################################
# Storage
###############################################################################

variable "root_volume_size" {
  type    = number
  default = 300
}

variable "data_volume_size" {
  description = "Secondary EBS (containerd LVM) size in GiB."
  type        = number
  default     = 100
}

variable "enable_local_lvm" {
  description = "LVM-stripe the instance-store NVMe into a single mount (model cache / scratch)."
  type        = bool
  default     = true
}

variable "local_lvm_vg_name" {
  type    = string
  default = "vg_local"
}

variable "local_lvm_lv_name" {
  type    = string
  default = "lv_scratch"
}

variable "local_lvm_mount" {
  type    = string
  default = "/data"
}

variable "local_lvm_fs" {
  type    = string
  default = "xfs"
}

variable "local_lvm_stripe_kb" {
  type    = number
  default = 256
}

###############################################################################
# Labels / taints / tags
###############################################################################

variable "extra_node_labels" {
  description = "Extra K8s node labels merged on top of workload-type/gpu-instance-type/purchase-option. Injected via kubelet --node-labels."
  type        = map(string)
  default     = {}
}

variable "node_taints" {
  description = "K8s node taints in kubelet --register-with-taints format (key=value:Effect)."
  type        = list(string)
  default     = ["nvidia.com/gpu=true:NoSchedule"]
}

variable "extra_asg_tags" {
  description = "Extra tags on the ASG (governance: Owner / CostCenter / Environment). Merged on top of the CA discovery / scale-from-zero tags."
  type        = map(string)
  default     = {}
}

variable "asg_suspended_processes" {
  description = <<-EOT
    ASG processes to suspend. Default disables ALL ASG-driven self-healing
    (ReplaceUnhealthy + AZRebalance) so instance IDs stay stable. Do NOT add
    Launch (breaks scale-up) or Terminate (breaks targeted retire).
  EOT
  type        = list(string)
  default     = ["ReplaceUnhealthy", "AZRebalance"]

  validation {
    condition     = !contains(var.asg_suspended_processes, "Launch") && !contains(var.asg_suspended_processes, "Terminate")
    error_message = "Do not suspend Launch (breaks CA scale-up) or Terminate (breaks targeted retire)."
  }
}
