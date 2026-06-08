variable "region" {
  type    = string
  default = "us-west-2"
}

variable "cluster_name" {
  description = "已有 EKS 集群名称"
  type        = string
}

variable "vpc_id" {
  description = "GPU 节点所在 VPC ID"
  type        = string
}

variable "cluster_security_group_id" {
  description = <<-EOT
    EKS 集群安全组 ID（控制面 <-> 节点通信用的 SG）。获取方式：
      aws eks describe-cluster --name <集群名> \
        --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text
    Part 1 会在此 SG 上加一条入向规则，允许 GPU 节点 SG 的流量进入。
  EOT
  type        = string
}

variable "name_prefix" {
  description = "所有资源名的前缀"
  type        = string
  default     = "eks-gpu"
}

variable "create_access_entry" {
  description = <<-EOT
    是否通过 EKS Access Entry（type EC2_LINUX）把 GPU 节点 IAM role 注册进集群。
    默认 true。

    仅在以下场景设 false：
      - 集群 auth mode 是 CONFIG_MAP-only（不支持 Access Entry）
      - 你选择手动把 role 加进 aws-auth ConfigMap

    API_AND_CONFIG_MAP 集群（aws-samples 默认创建的模式）下保持 true 即可，
    Access Entry 和已有 aws-auth 条目互不冲突。
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "附加到所有资源的额外 tag（如 Team / Environment）"
  type        = map(string)
  default     = {}
}

###############################################################################
# Addons 前置资源（SA + IAM + Pod Identity）
###############################################################################

variable "cluster_endpoint" {
  description = "EKS API endpoint（kubernetes provider 连接用）。从 cluster/ output 或 aws eks describe-cluster 获取。"
  type        = string
}

variable "cluster_ca" {
  description = "EKS 集群 CA 证书 base64（kubernetes provider 连接用）。从 cluster/ output 或 aws eks describe-cluster 获取。"
  type        = string
}

variable "install_cluster_autoscaler_prereqs" {
  description = <<-EOT
    是否创建 Cluster Autoscaler 的前置资源（SA + IAM role + Pod Identity）。
    默认 true。helm install 在 MANUAL_PLUGINS.md 里手动装。
    客户自带 CA 时设 false。
  EOT
  type        = bool
  default     = true
}

variable "install_alb_controller_prereqs" {
  description = <<-EOT
    是否创建 ALB Controller 的前置资源（SA + IAM policy/role + Pod Identity）。
    默认 true。helm install 在 MANUAL_PLUGINS.md 里手动装。
    不需要 ALB Controller 时设 false。
  EOT
  type        = bool
  default     = true
}
