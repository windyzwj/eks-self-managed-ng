# Part 2 — Self-Managed GPU Node Group (customer, repeatable)

Stands up **one** self-managed GPU node group — a Launch Template (with EFA
multi-NIC layout) + an ASG (no self-healing) that joins an existing EKS
cluster via `nodeadm`. Apply once per pool; copy the directory or wrap in a
`for_each` module for several pools (e.g. 3 ODCRs).

Depends on [`../prerequisites`](../prerequisites) having been applied — it
consumes that stack's IAM role / instance profile / node SG outputs.

## Lifecycle model — NO self-healing (deliberate)

| Setting | Effect |
|---|---|
| `suspended_processes = [ReplaceUnhealthy, AZRebalance]` | ASG never terminates+replaces an instance on its own → **instance IDs are stable** |
| `health_check_type = "EC2"` | ALB target marked unhealthy never triggers an ASG terminate |
| no `instance_refresh` | changing the Launch Template does **not** roll instances |
| `lifecycle ignore_changes=[desired_capacity]` | Cluster Autoscaler owns desired; terraform won't drift it back |

You own node lifecycle: failed nodes stay until you act; K8s upgrades are a
manual cordon/drain/terminate you drive.

## Apply

```bash
cd node-group
# Paste the hint block from `terraform output node_group_tfvars_hint` in Part 1,
# then add the pool-specific bits:
cat >> terraform.tfvars <<EOF
cluster_endpoint  = "https://XXXX.gr7.<region>.eks.amazonaws.com"
cluster_ca        = "LS0tLS1CRUdJ...."     # base64, raw describe-cluster value
service_ipv4_cidr = "172.20.0.0/16"        # your cluster's actual service CIDR
subnet_ids        = ["subnet-xxxx"]        # single AZ for ODCR/CB
name_prefix       = "eks-gpu-b300-odcr1"   # UNIQUE per pool
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

Gather cluster_endpoint / cluster_ca / service_ipv4_cidr:

```bash
aws eks describe-cluster --name <c> --region <r> --query 'cluster.endpoint' --output text
aws eks describe-cluster --name <c> --region <r> --query 'cluster.certificateAuthority.data' --output text
aws eks describe-cluster --name <c> --region <r> --query 'cluster.kubernetesNetworkConfig.serviceIpv4Cidr' --output text
```

## EFA multi-NIC — automatic per instance type

You only set `instance_type`; the NIC layout is looked up internally:

| instance_type | NICs | layout |
|---|---|---|
| p6-b300.48xlarge | 17 | NIC0 = plain ENA, NIC1-16 = EFA-only |
| p5.48xlarge | 32 | NIC0 = ENA+EFA, NIC1-31 = EFA-only |
| p5en.48xlarge | 16 | NIC0 = ENA+EFA, NIC1-15 = EFA-only |
| p6-b200.48xlarge | 8 | NIC0 = ENA+EFA, NIC1-7 = EFA-only |
| g6e/g7e.* | 1-4 | see code |

**Do not hand-write network interfaces** — the layout table handles it.
Override only with `efa_card_count_override` for an unlisted type.

## Pricing modes

| `purchase_mode` | extra inputs |
|---|---|
| `on_demand` | — |
| `spot` | — (one-time, terminate-on-interruption) |
| `odcr` | `capacity_reservation_id` (required) |
| `capacity_block` | `capacity_reservation_id` (required) |

## Day-2 operations

```bash
# Scale: edit desired_size -> terraform apply (or let Cluster Autoscaler do it)

# Retire ONE specific node (IDs are stable; nothing auto-replaces it):
kubectl cordon <node>
kubectl drain  <node> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node>
aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id i-xxx --should-decrement-desired-capacity --region <region>

# Upgrade AMI/LT (NOT automatic):
#   update gpu_ami_release_version -> terraform apply (new LT version)
#   then drain + terminate each node; replacements come up on the new template.
```

## Cluster Autoscaler

This stack inlines the discovery + scale-from-zero tags on the ASG:

```
k8s.io/cluster-autoscaler/enabled = true
k8s.io/cluster-autoscaler/<cluster> = owned
k8s.io/cluster-autoscaler/node-template/label/workload-type = gpu
k8s.io/cluster-autoscaler/node-template/label/gpu-instance-type = <type>
k8s.io/cluster-autoscaler/node-template/taint/nvidia.com/gpu = true:NoSchedule
k8s.io/cluster-autoscaler/node-template/resources/nvidia.com/gpu = <count>
k8s.io/cluster-autoscaler/node-template/resources/vpc.amazonaws.com/efa = <count>
```

Bring your own CA with:
```
--node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/<cluster>,k8s.io/cluster-autoscaler/enabled
--balance-similar-node-groups
--max-node-provision-time=15m
```
