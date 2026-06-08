###############################################################################
# 集群上下文（来自 `aws eks describe-cluster` / Part 1 output）
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
  description = "EKS API server endpoint（https://...）"
  type        = string
}

variable "cluster_ca" {
  description = "EKS 集群 CA 证书，base64 编码（describe-cluster 返回的原始值，不解码）"
  type        = string
}

variable "cluster_security_group_id" {
  description = "EKS 集群安全组 ID（控制面 <-> 节点）"
  type        = string
}

variable "service_ipv4_cidr" {
  description = <<-EOT
    集群的 K8s Service CIDR。nodeadm 用它配置 kubelet。获取方式：
      aws eks describe-cluster --name <集群名> \
        --query 'cluster.kubernetesNetworkConfig.serviceIpv4Cidr' --output text
    EKS 默认 172.20.0.0/16。填你集群的实际值。
  EOT
  type        = string
  default     = "172.20.0.0/16"
}

variable "vpc_id" {
  description = "VPC ID（用于打 tag / 引用）"
  type        = string
  default     = ""
}

###############################################################################
# 前置资源（Part 1 的 output）
###############################################################################

variable "existing_node_role_arn" {
  description = "prerequisites 的 gpu_node_role_arn output"
  type        = string
}

variable "existing_instance_profile_name" {
  description = "prerequisites 的 gpu_instance_profile_name output"
  type        = string
}

variable "existing_node_sg_id" {
  description = "prerequisites 的 gpu_node_sg_id output（共享 GPU SG，EFA 自通）"
  type        = string
}

variable "additional_sg_ids" {
  description = "额外附加到每张网卡的安全组 ID"
  type        = list(string)
  default     = []
}

###############################################################################
# 节点组形态
###############################################################################

variable "name_prefix" {
  description = "本节点组资源名前缀。多个池必须用不同值（如 eks-gpu-b300-odcr1）"
  type        = string
  default     = "eks-gpu-ng"
}

variable "instance_type" {
  description = "实例类型"
  type        = string
  default     = "p6-b300.48xlarge"
}

variable "desired_size" {
  description = "期望节点数。CA 可能在运行时修改（terraform 不漂移）。"
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
  description = "ASG 子网列表。ODCR/CB 场景一般只填对应 AZ 的单个子网。"
  type        = list(string)
}

variable "key_name" {
  description = "EC2 Key Pair（可选；留空 = 只能通过 SSM 登录）"
  type        = string
  default     = ""
}

###############################################################################
# AMI
###############################################################################

variable "eks_version" {
  description = "EKS 版本号，用于 SSM 查询 EKS-NVIDIA AMI"
  type        = string
  default     = "1.35"
}

variable "gpu_ami_release_version" {
  description = "锁定 EKS-NVIDIA AMI 发布版本（如 v20260527）。空 = SSM recommended。设了 custom_ami_id 时忽略。"
  type        = string
  default     = ""
}

variable "custom_ami_id" {
  description = "用自定义 AMI ID 完全覆盖 SSM 查询（必须从 EKS-NVIDIA base 派生）。空 = 走 SSM。"
  type        = string
  default     = ""

  validation {
    condition     = var.custom_ami_id == "" || can(regex("^ami-[0-9a-f]+$", var.custom_ami_id))
    error_message = "custom_ami_id 必须为空或有效的 AMI ID（^ami-[0-9a-f]+$）"
  }
}

###############################################################################
# 定价 / 容量
###############################################################################

variable "purchase_mode" {
  description = "购买模式：on_demand / spot / odcr / capacity_block"
  type        = string
  default     = "on_demand"
  validation {
    condition     = contains(["on_demand", "spot", "odcr", "capacity_block"], var.purchase_mode)
    error_message = "purchase_mode 必须是 on_demand / spot / odcr / capacity_block"
  }
}

variable "capacity_reservation_id" {
  description = "Capacity Reservation ID —— purchase_mode 为 odcr 或 capacity_block 时必填"
  type        = string
  default     = ""
}

variable "placement_group_name" {
  description = "Cluster placement group 名称（可选；单 AZ 多节点 NCCL 推荐）"
  type        = string
  default     = ""
}

###############################################################################
# EFA
###############################################################################

variable "efa_card_count_override" {
  description = "手动指定 EFA-only 网卡数。-1 = 按 instance_type 查表自动判断。"
  type        = number
  default     = -1
}

variable "install_efa_userspace" {
  description = "是否在 user-data 里安装 EFA userspace（libfabric-aws）。默认 true（节点有 NAT）。完全 air-gap 且 AMI 预装了 libfabric 时设 false。"
  type        = bool
  default     = true
}

variable "efa_installer_version" {
  description = "aws-efa-installer 版本。B300 至少需要 1.47+。"
  type        = string
  default     = "1.48.0"
}

###############################################################################
# 存储
###############################################################################

variable "root_volume_size" {
  description = "根卷大小（GiB）。用自定义 AMI 时必须 >= AMI snapshot 大小。"
  type        = number
  default     = 300
}

variable "data_volume_size" {
  description = "第二块 EBS（containerd LVM）大小（GiB）"
  type        = number
  default     = 100
}

variable "enable_local_lvm" {
  description = "把 Instance Store NVMe LVM 条带成单一挂载点（模型缓存 / scratch）"
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
# 标签 / 污点 / ASG tag
###############################################################################

variable "extra_node_labels" {
  description = "额外 K8s 节点 label，merge 到 workload-type/gpu-instance-type/purchase-option 之上。通过 kubelet --node-labels 注入。"
  type        = map(string)
  default     = {}
}

variable "node_taints" {
  description = "K8s 节点污点，格式同 kubelet --register-with-taints（key=value:Effect）"
  type        = list(string)
  default     = ["nvidia.com/gpu=true:NoSchedule"]
}

variable "extra_asg_tags" {
  description = "ASG 上额外 tag（治理用：Owner / CostCenter / Environment）。会 merge 到 CA discovery / scale-from-zero tag 之上。"
  type        = map(string)
  default     = {}
}

variable "asg_suspended_processes" {
  description = <<-EOT
    ASG 挂起的进程。默认关闭所有 ASG 驱动的自愈
    （ReplaceUnhealthy + AZRebalance），保持实例 ID 稳定。
    不要加 Launch（会破坏扩容）或 Terminate（会破坏退机）。
  EOT
  type        = list(string)
  default     = ["ReplaceUnhealthy", "AZRebalance"]

  validation {
    condition     = !contains(var.asg_suspended_processes, "Launch") && !contains(var.asg_suspended_processes, "Terminate")
    error_message = "不要挂起 Launch（会破坏 CA 扩容）或 Terminate（会破坏指定退机）。"
  }
}
