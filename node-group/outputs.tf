output "asg_name" {
  description = "ASG 名称。用于：aws autoscaling terminate-instance-in-auto-scaling-group --auto-scaling-group-name <此值>"
  value       = aws_autoscaling_group.node.name
}

output "launch_template_id" {
  description = "Launch Template ID"
  value       = aws_launch_template.node.id
}

output "launch_template_latest_version" {
  description = "Launch Template 最新版本号"
  value       = aws_launch_template.node.latest_version
}

output "ami_id" {
  description = "实际使用的 EKS-NVIDIA AMI ID"
  value       = local.ami_id
}

output "total_nic_count" {
  description = "每个节点的网卡总数（1 主 + EFA-only）"
  value       = local.total_nic_count
}

output "efa_resource_count" {
  description = "每个节点注册的 vpc.amazonaws.com/efa 资源数"
  value       = local.efa_resource_count
}

output "usage" {
  value = <<-EOT

  =============================================
   Self-Managed GPU 节点组: ${var.name_prefix}
  =============================================
   集群:         ${var.cluster_name}
   实例类型:     ${var.instance_type}
   购买模式:     ${var.purchase_mode}
   网卡:         ${local.total_nic_count}（1 主 + ${local.efa_only_count} EFA-only）
   ASG:          ${aws_autoscaling_group.node.name}
   自愈:         关闭（suspended: ${join(", ", var.asg_suspended_processes)}）

   扩缩容:
     修改 desired_size -> terraform apply（或让 Cluster Autoscaler 自动调）

   退指定节点（实例 ID 稳定，不会自动补）:
     kubectl cordon <node>
     kubectl drain  <node> --ignore-daemonsets --delete-emptydir-data
     kubectl delete node <node>
     aws autoscaling terminate-instance-in-auto-scaling-group \
       --instance-id i-xxx --should-decrement-desired-capacity --region ${var.region}

   升级 AMI/LT（不会自动滚动——设计如此）:
     修改 gpu_ami_release_version / LT 参数 -> terraform apply
     然后逐台 drain + terminate；CA 或 desired_size 拉起新机器用新模板。

   销毁本节点组:
     terraform destroy
  =============================================
  EOT
}
