# EKS Self-Managed GPU 节点组

为**已有** EKS 集群提供自管 GPU 节点组 —— EFA 多网卡（B300 / p5 / p6 / g6e /
g7e）、LVM 存储、灵活定价（OD / Spot / ODCR / Capacity Block），且 **ASG 不自愈**
（实例 ID 稳定，客户驱动生命周期）。

适用于**私有集群**：平台团队拥有集群和集群级前置资源，应用团队在其上按需拉起/扩缩
GPU 节点组。

## 三段式结构

```
cluster/          Step 1 — 创建 EKS 集群（Terraform）
                  控制面 + 核心 Managed Addon（vpc-cni / kube-proxy /
                  pod-identity-agent / CoreDNS / Metrics Server）
                  + VPC Endpoints（带 create_vpc_endpoints 开关）

prerequisites/    Step 2 — GPU 节点前置资源 + Addons SA/IAM（Terraform）
                  GPU 节点 IAM role + instance profile + access entry +
                  共享 GPU SG（EFA 自通）+ cluster SG 入向规则
                  + CA 的 SA + IAM role + Pod Identity Association
                  + ALB Controller 的 SA + IAM policy/role + Pod Identity
                  └─ MANUAL_PLUGINS.md: 手动装 K8s 插件
                     （EFA / NVIDIA device plugin / CA helm / ALB helm）

node-group/       Step 3 — GPU 节点组（Terraform，可重复）
                  Launch Template（EFA 多网卡）+ ASG（无自愈）+
                  扩缩容。引用 Step 2 的 output。每个节点池 apply 一次;
                  多个池（如 3 个 ODCR）用 for_each / 多份拷贝。

legacy-single-file/   旧版单文件（仅供参考）
```

### 为什么拆分

| 关注点 | 所在位置 | 原因 |
|---|---|---|
| IAM role / access entry | prerequisites | 集群级单例；一个共享 role，不是每个 ASG 一个。需要 iam:* / eks:CreateAccessEntry 权限（平台/安全团队权限）|
| GPU 安全组 | prerequisites | 必须共享——EFA/NCCL 流量要求所有 GPU 节点在同一 SG 内互通，跨 ASG 也是 |
| GPU 插件（EFA / NVIDIA） | prerequisites（手动） | DaemonSet，装一次即可；在有网络的窗口装好，节点起来时不再依赖 helm fetch |
| Launch Template + ASG | node-group | 可重复创建/扩缩的部分。应用团队拥有，引用平台 output，不需要 IAM 创建权限 |

## 流程

```
1. 平台: cd cluster && terraform apply
          → 拿到 cluster_endpoint / cluster_ca / cluster_sg_id / service_ipv4_cidr
2. 平台: cd prerequisites && terraform apply
          → 拿到 gpu_instance_profile_name / gpu_node_sg_id 等
3. 平台: 手动装 K8s 插件（prerequisites/MANUAL_PLUGINS.md）
          GPU plugin + CA helm + ALB helm
4. 应用团队: cd node-group && terraform apply（粘贴 hint + 填池子参数）
   对每个额外池重复步骤 4
```

## 核心设计点

- **无自愈** —— `suspended_processes=[ReplaceUnhealthy,AZRebalance]`，
  `health_check_type=EC2`，无 `instance_refresh`。实例 ID 稳定；
  用 `terminate-instance-in-auto-scaling-group --instance-id ... --should-decrement-desired-capacity` 退指定机器。
- **EFA 多网卡自动** —— 只设 `instance_type`，NIC 布局（如 B300 = 17 NIC）
  内部查表自动生成。禁止手写网卡配置。
- **外部 Cluster Autoscaler 就绪** —— ASG 上带标准 discovery + scale-from-zero
  tag；自带 CA 零额外配置。
- **私有集群感知** —— 节点通过 NAT / VPC endpoint 拉取。EFA installer 启动时
  拉取（`install_efa_userspace=false` 可关闭，改用预装 libfabric 的自定义 AMI）。

## 开始

- [prerequisites/README.md](prerequisites/README.md) — Part 1
- [prerequisites/MANUAL_PLUGINS.md](prerequisites/MANUAL_PLUGINS.md) — GPU 插件
- [node-group/README.md](node-group/README.md) — Part 2
