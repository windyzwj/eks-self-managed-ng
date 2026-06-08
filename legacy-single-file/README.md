# Legacy single-file version

This is the original all-in-one `main.tf` — it creates the IAM role, SG, Launch
Template, and ASG in a single `terraform apply`. Kept for reference and for
quick one-off node groups.

For the recommended two-part layout (platform-managed prerequisites +
repeatable per-pool node groups), use [`../prerequisites`](../prerequisites)
and [`../node-group`](../node-group) instead. See the [top-level
README](../README.md) for why.

> Note: this legacy version authorizes nodes via the **aws-auth ConfigMap**
> (manual `kubectl edit` step in its output) and uses `instance_refresh`
> (rolling replace on LT change → instance IDs change). The two-part version
> uses an EKS **Access Entry** and disables self-healing for stable instance
> IDs.
