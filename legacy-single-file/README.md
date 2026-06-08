# 旧版单文件（仅供参考）

这是原始的全合一 `main.tf` —— 在一次 `terraform apply` 里创建 IAM role、SG、
Launch Template、ASG。保留作为参考和快速一次性节点组使用。

推荐使用两段式结构 [`../prerequisites`](../prerequisites) +
[`../node-group`](../node-group)。详见 [顶层 README](../README.md)。

> 注意：此旧版通过 **aws-auth ConfigMap** 授权节点（需手动 `kubectl edit`），
> 且使用 `instance_refresh`（LT 变更时滚动替换所有节点 → 实例 ID 变化）。
> 两段式版本使用 EKS **Access Entry** 并关闭自愈（实例 ID 稳定）。
