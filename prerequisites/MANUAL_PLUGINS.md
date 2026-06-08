# Manual GPU plugin install (one-time, per cluster)

The Terraform in this directory creates the **AWS-side** prerequisites (IAM,
SG, access entry). The **Kubernetes-side** GPU plugins are installed manually
with `kubectl` / `helm` — once per cluster, before or after GPU nodes exist.

They're DaemonSets, so installing them with **zero GPU nodes is fine**:
`desired=0` until nodes join, then they auto-roll onto every matching node.
Install them in your cluster-build window so node bring-up never depends on a
helm fetch.

> **Private cluster note**: your bastion may have no outbound internet. The
> chart fetch (`helm repo add ...`) and some images (`nvcr.io`, Docker Hub)
> may be unreachable. Mirror charts + images to your internal registry / pull
> them in a connected window first. The EFA plugin image lives in **public
> ECR** and is reachable through a VPC ECR endpoint without internet.

## nodeSelector / toleration contract

Every plugin must land on GPU nodes. The `node-group` stack labels and taints
nodes as:

```
labels:  workload-type=gpu
         gpu-instance-type=<type>
         purchase-option=<mode>
taints:  nvidia.com/gpu=true:NoSchedule
```

So every plugin needs:
- `nodeSelector: workload-type=gpu`
- `toleration: key=nvidia.com/gpu, operator=Exists, effect=NoSchedule`
- (recommended) `priorityClassName: system-node-critical`

## Minimum set (required for GPU + EFA workloads)

### 1. NVIDIA device plugin — registers `nvidia.com/gpu`

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin   # or internal mirror
helm repo update

helm install nvidia-device-plugin nvdp/nvidia-device-plugin \
  --namespace kube-system \
  --version 0.19.1 \
  --set gfd.enabled=true \
  --set mofedEnabled=false \
  --set nodeSelector."workload-type"=gpu \
  --set-json 'tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]'
```

- `mofedEnabled=false` — the AWS EFA plugin owns `/dev/infiniband/uverbs*`;
  leaving NVIDIA's mofed on causes a conflict.
- image `nvcr.io/nvidia/k8s-device-plugin:v0.19.1` — **needs internet or a
  mirror**. For air-gapped nodes set `--set image.repository=<your-mirror>`.

### 2. EFA device plugin — registers `vpc.amazonaws.com/efa`

The default chart's `nodeSelector` is `aws.amazon.com/efa.present=true`, which
your nodes do NOT have. **You must override it to `workload-type=gpu`** or the
DaemonSet never schedules.

```bash
helm repo add eks https://aws.github.io/eks-charts   # or internal mirror
helm repo update

helm install aws-efa-k8s-device-plugin eks/aws-efa-k8s-device-plugin \
  --namespace kube-system \
  --set nodeSelector."workload-type"=gpu \
  --set-json 'tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]'
```

The EFA plugin image is in public ECR (`602401143452.dkr.ecr.<region>...`),
reachable via a VPC ECR endpoint — no internet needed for the image itself.

## Optional (monitoring / health)

### 3. DCGM exporter — per-pod GPU metrics

```bash
helm install dcgm-exporter \
  https://nvidia.github.io/dcgm-exporter/helm-charts/dcgm-exporter \
  --namespace kube-system \
  --version 4.8.2 \
  --set nodeSelector."workload-type"=gpu \
  --set serviceMonitor.enabled=false \
  --set-json 'tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]'
```

`serviceMonitor.enabled=false` unless you run the Prometheus Operator (else it
fails on a missing ServiceMonitor CRD).

### 4. node-problem-detector — surfaces GPU XID / kernel errors

```bash
helm install node-problem-detector \
  https://charts.deliveryhero.io/node-problem-detector \
  --namespace kube-system \
  --version 2.3.14 \
  --set nodeSelector."workload-type"=gpu \
  --set-json 'tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]'
```

## Verify

Before GPU nodes exist (everything `desired=0` is normal):

```bash
kubectl get ds -n kube-system | grep -E "efa|nvidia|dcgm|node-problem"
```

After GPU nodes join (via the node-group stack):

```bash
kubectl get ds -n kube-system | grep -E "efa|nvidia"     # desired/ready track node count

kubectl describe node <gpu-node> | grep -E "nvidia.com/gpu|vpc.amazonaws.com/efa"
# nvidia.com/gpu:        8
# vpc.amazonaws.com/efa: 16   (B300 = 16)
```

## Troubleshooting

`kubectl get pods -n kube-system -l <label> -o wide` then:

| Symptom | Cause | Fix |
|---|---|---|
| No pods created on a GPU node | nodeSelector mismatch | node missing `workload-type=gpu` — check node-group labels |
| Pod Pending, "untolerated taint nvidia.com/gpu" | missing toleration | add the toleration `--set-json` above |
| Pod ImagePullBackOff | air-gapped image | mirror image to internal registry, `--set image.repository=...` |
| `vpc.amazonaws.com/efa` not appearing | EFA plugin not on node | confirm EFA plugin nodeSelector override applied |
