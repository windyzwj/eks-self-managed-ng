output "gpu_node_role_arn" {
  description = "GPU node IAM role ARN. Pass to node-group as existing_node_role_arn. Also the role to add to aws-auth if create_access_entry=false."
  value       = aws_iam_role.gpu_node.arn
}

output "gpu_node_role_name" {
  description = "GPU node IAM role name."
  value       = aws_iam_role.gpu_node.name
}

output "gpu_instance_profile_name" {
  description = "Instance profile name. Pass to node-group as existing_instance_profile_name."
  value       = aws_iam_instance_profile.gpu_node.name
}

output "gpu_node_sg_id" {
  description = "Shared GPU node security group ID (EFA self-allow). Pass to node-group as existing_node_sg_id."
  value       = aws_security_group.gpu_node.id
}

output "access_entry_created" {
  description = "Whether an EKS Access Entry was created for the node role."
  value       = var.create_access_entry
}

output "node_group_tfvars_hint" {
  description = "Copy-paste starter for the node-group stack's terraform.tfvars."
  value       = <<-EOT

    # --- paste into node-group/terraform.tfvars ---
    existing_node_role_arn         = "${aws_iam_role.gpu_node.arn}"
    existing_instance_profile_name = "${aws_iam_instance_profile.gpu_node.name}"
    existing_node_sg_id            = "${aws_security_group.gpu_node.id}"
    cluster_security_group_id      = "${var.cluster_security_group_id}"
    cluster_name                   = "${var.cluster_name}"
    vpc_id                         = "${var.vpc_id}"
    region                         = "${var.region}"
  EOT
}
