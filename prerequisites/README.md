# Part 1 — GPU Node Prerequisites (platform, one-time)

Creates the **cluster-level singletons** that every self-managed GPU node
group shares. Run once per cluster. The [`../node-group`](../node-group) stack
consumes the outputs here.

## What it creates (AWS, via Terraform)

| Resource | Why it's here (not per-ASG) |
|---|---|
| GPU node IAM role + 4 EKS managed policies + nodeadm inline policy | Cluster-level singleton — one role shared by all GPU ASGs |
| Instance profile | Self-managed ASGs launch from a Launch Template, which needs an instance profile |
| EKS Access Entry (`EC2_LINUX`) | Registers the role with the cluster so nodes can join (API auth) |
| GPU security group + EFA self-allow rules | Shared SG so EFA/NCCL traffic flows across nodes in different ASGs |
| Cluster SG ingress from node SG | Managed NGs got this from EKS automatically; self-managed must declare it |

## What it does NOT create

- The node groups themselves (ASG / Launch Template) — that's [`../node-group`](../node-group).
- The Kubernetes GPU plugins (EFA / NVIDIA device plugin) — those are
  installed manually, see [MANUAL_PLUGINS.md](MANUAL_PLUGINS.md).

## Prerequisites

- An existing **private** EKS cluster.
- Cluster auth mode `API_AND_CONFIG_MAP` or `API` (so Access Entry works).
  If your cluster is `CONFIG_MAP`-only, set `create_access_entry=false` and
  add the role to aws-auth manually (see below).

## Inputs you need to gather

```bash
CLUSTER=<your-cluster>
REGION=<your-region>

aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text   # cluster_security_group_id
aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text                    # vpc_id
```

## Apply

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

The `node_group_tfvars_hint` output prints a ready-to-paste block for the
node-group stack's `terraform.tfvars`.

## aws-auth fallback (only if create_access_entry=false)

```bash
kubectl edit configmap aws-auth -n kube-system
# add under mapRoles:
# - rolearn: <gpu_node_role_arn output>
#   username: system:node:{{EC2PrivateDNSName}}
#   groups:
#     - system:bootstrappers
#     - system:nodes
```

## Outputs (feed into Part 2)

| Output | node-group variable |
|---|---|
| `gpu_node_role_arn` | `existing_node_role_arn` |
| `gpu_instance_profile_name` | `existing_instance_profile_name` |
| `gpu_node_sg_id` | `existing_node_sg_id` |

## Next steps

1. Install Kubernetes GPU plugins — [MANUAL_PLUGINS.md](MANUAL_PLUGINS.md)
2. Stand up node groups — [../node-group/README.md](../node-group/README.md)
