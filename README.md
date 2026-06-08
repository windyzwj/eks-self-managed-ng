# EKS Self-Managed GPU Node Groups

Self-managed GPU node groups for an **existing** EKS cluster — EFA multi-NIC
(B300 / p5 / p6 / g6e / g7e), LVM storage, flexible pricing (OD / Spot / ODCR /
Capacity Block), and **no ASG self-healing** (stable instance IDs, customer-
driven lifecycle).

Designed for **private clusters** where the platform team owns the cluster and
the cluster-level prerequisites, and an application team stands up / scales GPU
node groups on top.

## Two-part layout (recommended)

```
prerequisites/    Part 1 — platform, ONE-TIME per cluster (Terraform)
                  IAM role + instance profile + EKS access entry +
                  shared GPU SG (EFA self-allow) + cluster SG ingress
                  └─ MANUAL_PLUGINS.md: kubectl/helm install for the
                     Kubernetes GPU plugins (EFA + NVIDIA device plugin, ...)

node-group/       Part 2 — per pool, REPEATABLE (Terraform)
                  Launch Template (EFA multi-NIC) + ASG (no self-healing) +
                  scaling. Consumes Part 1 outputs. One apply per pool;
                  for_each / copies for several pools (e.g. 3 ODCRs).

legacy-single-file/   The original all-in-one main.tf (reference only)
```

### Why split

| Concern | Lives in | Reason |
|---|---|---|
| IAM role / access entry | prerequisites | Cluster-level singleton; one shared role, not one-per-ASG. Touches iam:* / eks:CreateAccessEntry (platform/security perms). |
| GPU security group | prerequisites | Must be shared so EFA/NCCL spans nodes across different ASGs. |
| GPU plugins (EFA / NVIDIA) | prerequisites (manual) | DaemonSets, installed once; install in a connected window so node bring-up never waits on a helm fetch. |
| Launch Template + ASG | node-group | The thing you create/scale repeatedly. App team owns it, references the platform outputs, needs no IAM-create perms. |

## Flow

```
1. platform: cd prerequisites && terraform apply
              └─ copy `node_group_tfvars_hint` output
2. platform: kubectl/helm install GPU plugins  (prerequisites/MANUAL_PLUGINS.md)
3. app team: cd node-group && terraform apply   (paste hint + pool specifics)
   repeat step 3 for each additional pool
```

## Key design points

- **No self-healing** — `suspended_processes=[ReplaceUnhealthy,AZRebalance]`,
  `health_check_type=EC2`, no `instance_refresh`. Instance IDs are stable;
  you retire specific nodes with
  `terminate-instance-in-auto-scaling-group --instance-id ... --should-decrement-desired-capacity`.
- **EFA multi-NIC is automatic** — you set `instance_type`, the NIC layout
  (e.g. B300 = 17 NICs) is looked up internally. Never hand-write NICs.
- **External Cluster Autoscaler ready** — ASGs carry the standard discovery +
  scale-from-zero tags; bring your own CA, zero extra config.
- **Private cluster aware** — nodes pull via NAT / VPC endpoints. EFA installer
  fetched at boot (set `install_efa_userspace=false` for fully air-gapped nodes
  using an AMI with libfabric pre-baked). See per-stack READMEs.

## Start here

- [prerequisites/README.md](prerequisites/README.md) — Part 1
- [prerequisites/MANUAL_PLUGINS.md](prerequisites/MANUAL_PLUGINS.md) — GPU plugins
- [node-group/README.md](node-group/README.md) — Part 2
