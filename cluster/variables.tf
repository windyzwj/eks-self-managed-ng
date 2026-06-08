variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  description = "EKS 集群名称"
  type        = string
}

variable "k8s_version" {
  description = "Kubernetes 版本"
  type        = string
  default     = "1.35"
}

variable "vpc_id" {
  description = "已有 VPC ID"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR（用于 endpoint SG ingress rule）"
  type        = string
}

variable "private_subnet_ids" {
  description = "私有子网 ID 列表（EKS 控制面 + VPC Endpoint 用，每个必须在不同 AZ）"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "公有子网 ID 列表（公有模式 ALB 用；私有集群可传空）"
  type        = list(string)
  default     = []
}

variable "cluster_mode" {
  description = "集群 API 访问模式：private（默认）或 public"
  type        = string
  default     = "private"
}

variable "public_access_cidrs" {
  description = "公有模式下允许访问 API 的 CIDR 列表"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "service_ipv4_cidr" {
  description = "K8s Service CIDR。创建后不可改。默认 172.20.0.0/16"
  type        = string
  default     = "172.20.0.0/16"
}

variable "kms_key_arn" {
  description = "KMS key ARN 用于 secrets envelope 加密。留空 = 不加密。"
  type        = string
  default     = ""
}

variable "enable_deletion_protection" {
  description = "EKS 集群删除保护"
  type        = bool
  default     = true
}

variable "enabled_cluster_log_types" {
  description = "控制面日志类型"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "extra_api_ingress_security_group_ids" {
  description = "额外允许访问 API（443）的 SG ID 列表（同 VPC 内的 bastion / CI）"
  type        = list(string)
  default     = []
}

variable "extra_api_ingress_cidrs" {
  description = "额外允许访问 API（443）的 CIDR 列表（DX / VPN / TGW）"
  type        = list(string)
  default     = []
}

variable "extra_cluster_admin_role_arns" {
  description = "额外 cluster-admin IAM role ARN 列表（不要填 apply 时的身份，那个已自动 admin）"
  type        = list(string)
  default     = []
}

###############################################################################
# VPC Endpoints 开关
###############################################################################

variable "create_vpc_endpoints" {
  description = <<-EOT
    是否创建 VPC Endpoints。默认 true。

    私有集群必须有 VPC Endpoint 让节点/Pod 访问 AWS 服务（EKS API、ECR、
    S3 等）。如果你的 VPC 已经由网络团队手动建好了这些 endpoint，设 false 跳过。
  EOT
  type        = bool
  default     = true
}

variable "install_coredns" {
  description = <<-EOT
    是否安装 CoreDNS EKS Managed Addon。CoreDNS 是 Deployment，需要 worker 节点
    才能 Ready（pod 需要调度）。

    如果你先建集群再起节点（分段式流程），第一次 apply 时设 false 跳过，
    等 system 节点 Ready 后改成 true 再 apply。
  EOT
  type        = bool
  default     = true
}

variable "install_metrics_server" {
  description = <<-EOT
    是否安装 Metrics Server EKS Managed Addon。同 CoreDNS，需要 worker 节点。
    分段式流程第一次 apply 时可设 false。
  EOT
  type        = bool
  default     = true
}

variable "vpc_endpoints_mode" {
  description = "VPC Endpoint 范围：minimal（4 个必需：eks/eks-auth/sts/ec2）或 full（+ecr/logs/ssm 等共 13 个）"
  type        = string
  default     = "full"
  validation {
    condition     = contains(["minimal", "full"], var.vpc_endpoints_mode)
    error_message = "vpc_endpoints_mode 必须是 minimal 或 full"
  }
}
