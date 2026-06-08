# Part 2 — Self-Managed GPU 节点组（客户侧，可重复）

创建**一个** self-managed GPU 节点组：Launch Template（EFA 多网卡）+ ASG（无自愈），
节点通过 `nodeadm` 加入已有 EKS 集群。每个池 apply 一次；多个池（如 3 个 ODCR）
用 `for_each` / 多份拷贝。

依赖 [`../prerequisites`](../prerequisites) 已 apply 完——消费那边的 IAM role /
instance profile / node SG output。

## 生命周期模型 —— 无自愈（刻意设计）

| 配置 | 效果 |
|---|---|
| `suspended_processes = [ReplaceUnhealthy, AZRebalance]` | ASG 永远不主动替换实例 → **实例 ID 稳定** |
| `health_check_type = "EC2"` | ALB target unhealthy 不触发 ASG terminate |
| 无 `instance_refresh` | 改 Launch Template 不滚动替换实例 |
| `lifecycle ignore_changes=[desired_capacity]` | Cluster Autoscaler 拥有 desired；terraform 不会漂移它 |

你拥有节点生命周期：故障节点留着等你处理；K8s 升级是你驱动的 cordon/drain/terminate。

## 使用

```bash
cd node-group
# 粘贴 Part 1 的 `terraform output node_group_tfvars_hint` 输出,
# 再加本池子的参数:
cat >> terraform.tfvars <<EOF
cluster_endpoint  = "https://XXXX.gr7.<region>.eks.amazonaws.com"
cluster_ca        = "LS0tLS1CRUdJ...."     # base64 原值
service_ipv4_cidr = "172.20.0.0/16"        # 你集群的实际 service CIDR
subnet_ids        = ["subnet-xxxx"]        # 单 AZ（ODCR/CB 对应 AZ）
name_prefix       = "eks-gpu-b300-odcr1"   # 每个池子唯一
instance_type     = "p6-b300.48xlarge"
purchase_mode     = "odcr"
capacity_reservation_id = "cr-xxxx"
desired_size      = 1
min_size          = 0
max_size          = 1
EOF

terraform init
terraform apply
```

获取 cluster_endpoint / cluster_ca / service_ipv4_cidr：

```bash
aws eks describe-cluster --name <集群名> --region <region> --query 'cluster.endpoint' --output text
aws eks describe-cluster --name <集群名> --region <region> --query 'cluster.certificateAuthority.data' --output text
aws eks describe-cluster --name <集群名> --region <region> --query 'cluster.kubernetesNetworkConfig.serviceIpv4Cidr' --output text
```

## EFA 多网卡 —— 按机型自动

只设 `instance_type`，NIC 布局内部查表：

| 机型 | 网卡总数 | 布局 |
|---|---|---|
| p6-b300.48xlarge | 17 | NIC0 = 纯 ENA，NIC1-16 = EFA-only |
| p5.48xlarge | 32 | NIC0 = ENA+EFA，NIC1-31 = EFA-only |
| p5en.48xlarge | 16 | NIC0 = ENA+EFA，NIC1-15 = EFA-only |
| p6-b200.48xlarge | 8 | NIC0 = ENA+EFA，NIC1-7 = EFA-only |
| g6e/g7e.* | 1-4 | 见代码 |

**禁止手写 network interfaces** —— 布局表自动处理。只有不在表里的新机型才用
`efa_card_count_override` 手动指定。

## 定价模式

| `purchase_mode` | 额外输入 |
|---|---|
| `on_demand` | 无 |
| `spot` | 无（one-time，中断即 terminate） |
| `odcr` | `capacity_reservation_id`（必填） |
| `capacity_block` | `capacity_reservation_id`（必填） |

## Day-2 操作

```bash
# 扩缩容：改 desired_size -> terraform apply（或让 Cluster Autoscaler 自己调）

# 退指定节点（实例 ID 稳定，不会自动补）：
kubectl cordon <node>
kubectl drain  <node> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node>
aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id i-xxx --should-decrement-desired-capacity --region <region>

# 升级 AMI/LT（不会自动滚动——设计如此）：
#   修改 gpu_ami_release_version -> terraform apply（新 LT version）
#   然后逐台 drain + terminate；CA 或 desired_size 会拉起新机器用新模板
```

## Cluster Autoscaler

本 stack 在 ASG 上 inline 了 discovery + scale-from-zero tag：

```
k8s.io/cluster-autoscaler/enabled = true
k8s.io/cluster-autoscaler/<集群名> = owned
k8s.io/cluster-autoscaler/node-template/label/workload-type = gpu
k8s.io/cluster-autoscaler/node-template/label/gpu-instance-type = <机型>
k8s.io/cluster-autoscaler/node-template/taint/nvidia.com/gpu = true:NoSchedule
k8s.io/cluster-autoscaler/node-template/resources/nvidia.com/gpu = <数量>
k8s.io/cluster-autoscaler/node-template/resources/vpc.amazonaws.com/efa = <数量>
```

自带 CA 启动参数建议：
```
--node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/<集群名>,k8s.io/cluster-autoscaler/enabled
--balance-similar-node-groups
--max-node-provision-time=15m
```
