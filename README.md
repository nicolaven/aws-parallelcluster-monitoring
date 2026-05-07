# Grafana Dashboard for AWS ParallelCluster

A monitoring solution for HPC clusters built with
[AWS ParallelCluster](https://aws.amazon.com/hpc/parallelcluster/).
Ships Prometheus, Grafana, node_exporter, pushgateway, nginx, and
[prometheus-slurm-exporter](https://github.com/rivosinc/prometheus-slurm-exporter)
as containers on the HeadNode, plus node_exporter and (optionally) the NVIDIA
DCGM exporter on every compute node.

Six ready-to-use dashboards are included:

* **ParallelCluster Summary** — general cluster + Slurm + storage metrics
* **HeadNode Details** — CPU, memory, network, storage for the head node
* **Compute Node List** — all compute nodes with links to per-node details
* **Compute Node Details** — per-node metrics
* **GPU Nodes Details** — NVIDIA metrics via DCGM
* **Cluster Logs** — CloudWatch Logs surfaced in Grafana
* **Cluster Costs** — list-price cost estimates (EC2, EBS, FSx, S3)

## Quickstart

Add the following to your ParallelCluster config — under both `HeadNode` and
each `SlurmQueue`:

```yaml
CustomActions:
  OnNodeConfigured:
    Script: https://raw.githubusercontent.com/aws-samples/aws-parallelcluster-monitoring/main/post-install.sh
    Args:
      - v1.0
Iam:
  AdditionalIamPolicies:
    - Policy: arn:aws:iam::aws:policy/CloudWatchFullAccess
    - Policy: arn:aws:iam::aws:policy/AWSPriceListServiceFullAccess
    - Policy: arn:aws:iam::aws:policy/AmazonSSMFullAccess
    - Policy: arn:aws:iam::aws:policy/AWSCloudFormationReadOnlyAccess
Tags:
  - Key: 'Grafana'
    Value: 'true'
```

The `v1.0` tag pins the monitoring stack to a known-good release.
Bump deliberately.

Full example: [parallelcluster-setup/pcluster.yaml](parallelcluster-setup/pcluster.yaml).

Open a security group allowing inbound 80/443 to the HeadNode, attach it as
`AdditionalSecurityGroups`, then browse to `https://<head-node-public-ip>/`.
Grafana login: `admin` / `Grafana4PC!` (change on first login; a per-cluster
SSM-managed password arrives in the next release).

## Supported operating systems

| OS                      | Status | Notes |
|-------------------------|--------|-------|
| Amazon Linux 2023       | ✅ recommended | ParallelCluster 3.8+ default |
| Amazon Linux 2          | ✅ | EOL June 2026 |
| Ubuntu 22.04 / 24.04    | ✅ | |
| RHEL / Rocky / Alma 9   | ✅ | Uses docker-ce upstream repo |
| CentOS Stream 9         | ✅ | |

Supported ParallelCluster versions: **3.10 – 3.15**.

## Solution components

| Component | Image / source | Pin |
|-----------|----------------|-----|
| Grafana | `grafana/grafana` | `11.2.2` |
| Prometheus | `prom/prometheus` | `v3.1.0` |
| Prometheus Pushgateway | `prom/pushgateway` | `v1.11.2` |
| Node Exporter | `quay.io/prometheus/node-exporter` | `v1.9.0` |
| NGINX | `nginx` | `1.27-alpine` |
| NVIDIA DCGM Exporter | `nvcr.io/nvidia/k8s/dcgm-exporter` | `4.0.0-4.0.0-ubuntu22.04` |
| prometheus-slurm-exporter | [rivosinc/prometheus-slurm-exporter](https://github.com/rivosinc/prometheus-slurm-exporter) | `1.8.0` |
| Docker Compose v2 plugin | upstream | `v2.29.7` |

All images are pinned — `latest` is never used. Bumps happen in
`installer/common.sh` and the compose files under `compose/`.

### Licensing

All bundled components are Apache-2.0, MIT, or compatible. The previous
GPLv3 `vpenso/prometheus-slurm-exporter` dependency has been replaced by
`rivosinc/prometheus-slurm-exporter` (Apache-2.0).

## Example dashboards

![ParallelCluster](docs/ParallelCluster.png?raw=true)
![Head Node](docs/HeadNode.png?raw=true)
![Compute Node List](docs/List.png?raw=true)
![Logs](docs/Logs.png?raw=true)
![Costs](docs/Costs.png?raw=true)

## Roadmap

This is the **Phase 1** release — unblock current users. Upcoming:

* **Phase 2** — per-cluster SSM-managed Grafana password, least-privilege
  IAM policy (closes #29), optional ACM + ALB in front of the HeadNode,
  optional Cognito SSO.
* **Phase 3** — dashboards migrated to Grafana template variables (removes
  all `sed __TOKEN__` replacement), real Cost Explorer datasource,
  Slurm job-level dashboard, EFA metrics. Adds native Slurm 25.11
  `/metrics/*` endpoints as an alternative data source.
* **Phase 4** — opt-in Amazon Managed Prometheus / Managed Grafana path
  (closes #13), CDK module, GitHub Actions CI (shellcheck, hadolint,
  smoke-test against a real pcluster), Renovate for image pins.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications).

## License

MIT-0 — see [LICENSE](LICENSE).
