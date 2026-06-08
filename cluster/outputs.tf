output "cluster_name" {
  description = "EKS 集群名称"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca" {
  description = "集群 CA 证书（base64）"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "EKS 集群安全组 ID（控制面 <-> 节点通信）"
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "service_ipv4_cidr" {
  description = "K8s Service CIDR"
  value       = aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr
}

output "k8s_version" {
  description = "集群 K8s 版本"
  value       = aws_eks_cluster.this.version
}

output "cluster_role_arn" {
  description = "集群 IAM role ARN"
  value       = aws_iam_role.cluster.arn
}

output "prerequisites_tfvars_hint" {
  description = "粘贴到 prerequisites/terraform.tfvars 的参数块"
  value       = <<-EOT

    # --- 粘贴到 prerequisites/terraform.tfvars ---
    region                    = "${var.region}"
    cluster_name              = "${aws_eks_cluster.this.name}"
    vpc_id                    = "${var.vpc_id}"
    cluster_security_group_id = "${aws_eks_cluster.this.vpc_config[0].cluster_security_group_id}"
  EOT
}
