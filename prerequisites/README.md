# Part 1 — GPU 节点前置资源（平台侧，一次性）

创建**集群级单例资源**，供所有 self-managed GPU 节点组共享。每集群只跑一次。
[`../node-group`](../node-group)（Part 2）消费本目录的 output。

## 创建的资源（AWS，Terraform）

| 资源 | 为什么放这里（不是每个 ASG 各建一份）|
|---|---|
| GPU 节点 IAM role + 4 个 EKS managed policy + nodeadm 内联 policy | 集群级单例——一个 role 被所有 GPU ASG 共享 |
| Instance profile | Self-managed ASG 从 LT 起实例时需要 instance profile |
| EKS Access Entry（`EC2_LINUX`）| 把 role 注册进集群，节点能通过 API auth join |
| GPU 安全组 + EFA 自通规则 | 共享 SG，EFA/NCCL 流量能跨不同 ASG 的节点 |
| Cluster SG 入向规则（来自 node SG）| Managed NG 由 EKS 自动加；self-managed 必须显式声明 |

## 不创建的东西

- 节点组本身（ASG / Launch Template）—— 在 [`../node-group`](../node-group)
- K8s GPU 插件（EFA / NVIDIA device plugin）—— 手动装，见
  [MANUAL_PLUGINS.md](MANUAL_PLUGINS.md)

## 前提条件

- 已有一个**私有** EKS 集群
- 集群 auth mode 为 `API_AND_CONFIG_MAP` 或 `API`（Access Entry 才能生效）。
  如果集群是 `CONFIG_MAP` only，设 `create_access_entry=false` 然后手动把 role
  加进 aws-auth（见下文）

## 需要收集的输入

```bash
CLUSTER=<集群名>
REGION=<region>

# cluster_security_group_id
aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text

# vpc_id
aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text
```

## 使用

```bash
cd prerequisites
cat > terraform.tfvars <<EOF
region                    = "$REGION"
cluster_name              = "$CLUSTER"
vpc_id                    = "vpc-xxxx"
cluster_security_group_id = "sg-xxxx"
name_prefix               = "eks-gpu"
EOF

terraform init
terraform apply
```

apply 完成后 `terraform output node_group_tfvars_hint` 会打印一段可直接粘到
node-group 的 `terraform.tfvars` 里的参数块。

## aws-auth 备选方案（仅 create_access_entry=false 时需要）

```bash
kubectl edit configmap aws-auth -n kube-system
# 在 mapRoles 下加：
# - rolearn: <gpu_node_role_arn output 的值>
#   username: system:node:{{EC2PrivateDNSName}}
#   groups:
#     - system:bootstrappers
#     - system:nodes
```

## Output（喂给 Part 2）

| Output | node-group 变量 |
|---|---|
| `gpu_node_role_arn` | `existing_node_role_arn` |
| `gpu_instance_profile_name` | `existing_instance_profile_name` |
| `gpu_node_sg_id` | `existing_node_sg_id` |

## 下一步

1. 手动装 K8s GPU 插件 —— [MANUAL_PLUGINS.md](MANUAL_PLUGINS.md)
2. 拉起节点组 —— [../node-group/README.md](../node-group/README.md)
