variable "region" {
  type    = string
  default = "us-west-2"
}

variable "cluster_name" {
  description = "Existing EKS cluster name."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID the GPU nodes run in."
  type        = string
}

variable "cluster_security_group_id" {
  description = <<-EOT
    The EKS cluster security group ID (the SG EKS created for the control
    plane <-> node communication). Find it via:
      aws eks describe-cluster --name <cluster> \
        --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text
    Part 1 adds an ingress rule on this SG allowing traffic from the GPU
    node SG.
  EOT
  type        = string
}

variable "name_prefix" {
  description = "Prefix for all created resource names."
  type        = string
  default     = "eks-gpu"
}

variable "create_access_entry" {
  description = <<-EOT
    Whether to register the GPU node IAM role with the cluster via an EKS
    Access Entry (type EC2_LINUX). Default true.

    Set false ONLY if your cluster is CONFIG_MAP-only, or you manage node
    authorization via the aws-auth ConfigMap. In that case add the role
    output (gpu_node_role_arn) to aws-auth manually — see README.

    On an API_AND_CONFIG_MAP cluster (the aws-samples default), leaving this
    true is correct and works alongside any existing aws-auth entries.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags applied to all created resources."
  type        = map(string)
  default     = {}
}
