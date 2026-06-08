# 手动安装 GPU 插件（每集群一次）

本目录的 Terraform 创建的是 **AWS 侧**前置资源（IAM / SG / access entry）。
**K8s 侧** GPU 插件用 `kubectl` / `helm` 手动装——每集群装一次,不管 GPU 节点
是否已起来。

它们都是 DaemonSet，**0 GPU 节点时装完全没问题**：`desired=0`，节点 join 后自动
铺上去。在集群搭建窗口把它们装好，后续节点起来时不再依赖 helm fetch。

> **私有集群提示**：堡垒机可能没外网。`helm repo add ...` 和部分镜像
> （`nvcr.io`、Docker Hub）可能不可达。提前在有网的环境 mirror chart + image
> 到内部 registry。EFA 插件镜像在 **公共 ECR**，通过 VPC ECR endpoint 可达，
> 不需要外网。

## nodeSelector / toleration 约定

所有插件都要落在 GPU 节点上。`node-group` 创建的节点带以下 label 和 taint：

```
labels:  workload-type=gpu
         gpu-instance-type=<机型>
         purchase-option=<定价模式>
taints:  nvidia.com/gpu=true:NoSchedule
```

所以每个插件都需要：
- `nodeSelector: workload-type=gpu`
- `toleration: key=nvidia.com/gpu, operator=Exists, effect=NoSchedule`
- （推荐）`priorityClassName: system-node-critical`

## 必装（GPU + EFA 工作负载必需）

### 1. NVIDIA device plugin — 注册 `nvidia.com/gpu`

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin   # 或内部 mirror
helm repo update

helm install nvidia-device-plugin nvdp/nvidia-device-plugin \
  --namespace kube-system \
  --version 0.19.1 \
  --set gfd.enabled=true \
  --set mofedEnabled=false \
  --set nodeSelector."workload-type"=gpu \
  --set-json 'tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]'
```

- `mofedEnabled=false` —— AWS EFA 插件拥有 `/dev/infiniband/uverbs*`，NVIDIA
  的 mofed 打开会冲突。
- 镜像 `nvcr.io/nvidia/k8s-device-plugin:v0.19.1` —— **需要外网或 mirror**。
  air-gap 节点需设 `--set image.repository=<你的 mirror>`。

### 2. EFA device plugin — 注册 `vpc.amazonaws.com/efa`

官方 chart 默认 `nodeSelector` 是 `aws.amazon.com/efa.present=true`，跟节点实际
label 不匹配。**必须覆盖成 `workload-type=gpu`**，否则 DaemonSet 永远不调度。

```bash
helm repo add eks https://aws.github.io/eks-charts   # 或内部 mirror
helm repo update

helm install aws-efa-k8s-device-plugin eks/aws-efa-k8s-device-plugin \
  --namespace kube-system \
  --set nodeSelector."workload-type"=gpu \
  --set-json 'tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]'
```

EFA 插件镜像在公共 ECR（`602401143452.dkr.ecr.<region>...`），通过 VPC ECR
endpoint 可达——**不需要外网**。

## 可选（监控 / 健康检查）

### 3. DCGM exporter — GPU pod 级别 metrics

```bash
helm install dcgm-exporter \
  --repo https://nvidia.github.io/dcgm-exporter/helm-charts \
  dcgm-exporter \
  --namespace kube-system \
  --version 4.8.2 \
  --set nodeSelector."workload-type"=gpu \
  --set serviceMonitor.enabled=false \
  --set-json 'tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]'
```

`serviceMonitor.enabled=false` —— 除非你装了 Prometheus Operator，否则缺
ServiceMonitor CRD 会 helm 报错。

### 4. node-problem-detector — 上报 GPU XID / 内核错误

```bash
helm install node-problem-detector \
  --repo https://charts.deliveryhero.io/ \
  node-problem-detector \
  --namespace kube-system \
  --version 2.3.14 \
  --set nodeSelector."workload-type"=gpu \
  --set-json 'tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]'
```

## 验证

GPU 节点还没起来时（`desired=0` 是正常状态）：

```bash
kubectl get ds -n kube-system | grep -E "efa|nvidia|dcgm|node-problem"
# 全部 0 0 0 0 0 —— 正常，等节点
```

GPU 节点 join 后（Part 2 terraform apply 之后）：

```bash
kubectl get ds -n kube-system | grep -E "efa|nvidia"
# desired/ready 跟上 GPU 节点数

kubectl describe node <gpu-node> | grep -E "nvidia.com/gpu|vpc.amazonaws.com/efa"
# nvidia.com/gpu:        8
# vpc.amazonaws.com/efa: 16   (B300 = 16)
```

## Cluster Autoscaler（需要 system 节点跑 pod）

prerequisites/ 的 Terraform 已经创建了 SA (`cluster-autoscaler`) + IAM role + Pod
Identity Association。这里只需要 helm install 装 controller pod。

```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update

helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --version 9.57.0 \
  --set fullnameOverride=cluster-autoscaler \
  --set autoDiscovery.clusterName=<集群名> \
  --set awsRegion=<region> \
  --set image.tag=v1.35.0 \
  --set rbac.serviceAccount.create=false \
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --set replicaCount=2 \
  --set extraArgs.balance-similar-node-groups=true \
  --set extraArgs.skip-nodes-with-local-storage=false \
  --set extraArgs.expander=least-waste \
  --set extraArgs.max-node-provision-time=15m
```

- `rbac.serviceAccount.create=false` —— SA 已由 TF 创建,不要重复建
- `image.tag` 跟 K8s 版本对齐（1.35 → v1.35.0）
- 需要 **system 节点**才能调度 controller pod
- 客户自带 CA 时跳过本段（prerequisites 里设 `install_cluster_autoscaler_prereqs=false`）

## ALB Controller（需要 system 节点跑 pod）

prerequisites/ 的 Terraform 已创建 SA (`aws-load-balancer-controller`) + IAM role/policy +
Pod Identity Association。这里只需 helm install。

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version 1.16.0 \
  --set clusterName=<集群名> \
  --set region=<region> \
  --set vpcId=<vpc-id> \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set image.tag=v2.14.1 \
  --set replicaCount=2
```

- `serviceAccount.create=false` —— SA 已由 TF 创建
- 不需要 ALB Controller 时跳过本段（prerequisites 里设 `install_alb_controller_prereqs=false`）

## 排查

`kubectl get pods -n kube-system -l <label> -o wide` 然后看：

| 症状 | 原因 | 修法 |
|---|---|---|
| GPU 节点上没创建 pod | nodeSelector 不匹配 | 确认节点有 `workload-type=gpu` label |
| Pod Pending，"untolerated taint nvidia.com/gpu" | 缺 toleration | 加上面的 `--set-json tolerations=...` |
| Pod ImagePullBackOff | air-gap 拉不到镜像 | mirror 到内部 registry，`--set image.repository=...` |
| `vpc.amazonaws.com/efa` 没出现在节点上 | EFA 插件没铺上来 | 确认 EFA plugin 的 nodeSelector 已覆盖为 `workload-type=gpu` |
