output "gpu_node_role_arn" {
  description = "GPU 节点 IAM role ARN。传给 node-group 的 existing_node_role_arn。如果 create_access_entry=false，也是需要加进 aws-auth 的 role。"
  value       = aws_iam_role.gpu_node.arn
}

output "gpu_node_role_name" {
  description = "GPU 节点 IAM role 名称"
  value       = aws_iam_role.gpu_node.name
}

output "gpu_instance_profile_name" {
  description = "Instance profile 名称。传给 node-group 的 existing_instance_profile_name。"
  value       = aws_iam_instance_profile.gpu_node.name
}

output "gpu_node_sg_id" {
  description = "共享 GPU 节点安全组 ID（EFA 自通）。传给 node-group 的 existing_node_sg_id。"
  value       = aws_security_group.gpu_node.id
}

output "access_entry_created" {
  description = "是否为节点 role 创建了 EKS Access Entry"
  value       = var.create_access_entry
}

output "node_group_tfvars_hint" {
  description = "可直接粘贴到 node-group/terraform.tfvars 的参数块"
  value       = <<-EOT

    # --- 粘贴到 node-group/terraform.tfvars ---
    existing_node_role_arn         = "${aws_iam_role.gpu_node.arn}"
    existing_instance_profile_name = "${aws_iam_instance_profile.gpu_node.name}"
    existing_node_sg_id            = "${aws_security_group.gpu_node.id}"
    cluster_security_group_id      = "${var.cluster_security_group_id}"
    cluster_name                   = "${var.cluster_name}"
    vpc_id                         = "${var.vpc_id}"
    region                         = "${var.region}"
  EOT
}
