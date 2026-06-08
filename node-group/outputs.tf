output "asg_name" {
  description = "ASG name. Use with: aws autoscaling terminate-instance-in-auto-scaling-group --auto-scaling-group-name <this>"
  value       = aws_autoscaling_group.node.name
}

output "launch_template_id" {
  value = aws_launch_template.node.id
}

output "launch_template_latest_version" {
  value = aws_launch_template.node.latest_version
}

output "ami_id" {
  description = "Resolved EKS-NVIDIA AMI ID in use."
  value       = local.ami_id
}

output "total_nic_count" {
  description = "Total network cards on each node (1 primary + EFA-only)."
  value       = local.total_nic_count
}

output "efa_resource_count" {
  description = "vpc.amazonaws.com/efa resource count advertised per node."
  value       = local.efa_resource_count
}

output "usage" {
  value = <<-EOT

  =============================================
   Self-Managed GPU Node Group: ${var.name_prefix}
  =============================================
   Cluster:        ${var.cluster_name}
   Instance type:  ${var.instance_type}
   Purchase mode:  ${var.purchase_mode}
   NICs:           ${local.total_nic_count} (1 primary + ${local.efa_only_count} EFA-only)
   ASG:            ${aws_autoscaling_group.node.name}
   Self-healing:   OFF (suspended: ${join(", ", var.asg_suspended_processes)})

   Scale up/down:
     edit desired_size -> terraform apply   (or let Cluster Autoscaler do it)

   Retire a SPECIFIC node (instance IDs are stable; nothing auto-replaces it):
     kubectl cordon <node>
     kubectl drain  <node> --ignore-daemonsets --delete-emptydir-data
     kubectl delete node <node>
     aws autoscaling terminate-instance-in-auto-scaling-group \
       --instance-id i-xxx --should-decrement-desired-capacity --region ${var.region}

   Upgrade AMI / LT (NOT automatic — ASG won't roll instances by design):
     update gpu_ami_release_version / LT inputs -> terraform apply
     then drain + terminate each node as above; CA (or desired_size) brings
     up replacements on the new template.

   Destroy this node group:
     terraform destroy
  =============================================
  EOT
}
