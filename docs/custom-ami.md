# Reducing compute node boot time with a custom AMI

## Why this matters

By default this solution is installed through a ParallelCluster **post-install (`OnNodeConfigured`) action** that runs [`post-install.sh`](../post-install.sh) → [`install-monitoring.sh`](../parallelcluster-setup/install-monitoring.sh) on every node.

On a compute node, that script runs **every time a node is launched** (i.e. on every scale-up event, because ParallelCluster launches compute instances dynamically as jobs are queued). Each boot it has to:

1. `yum install docker` and start the service
2. Download the `docker-compose` binary from GitHub
3. **GPU nodes only:** add the NVIDIA container repository, `yum install nvidia-docker2`, and restart Docker
4. `docker-compose up -d`, which **pulls the container images over the network** (`node-exporter`, plus `dcgm-exporter` on GPU nodes)

All of these are network-bound steps that add latency between "instance launched" and "node ready to run jobs". The bigger your fleet churn, the more often you pay this cost.

The fix is to move that work out of the boot path and **bake the packages and images into a custom compute-node AMI**, so at boot the node only has to start already-present containers from already-cached images.

## Important: custom AMIs are tied to a ParallelCluster version

A ParallelCluster custom AMI is built **on top of the official ParallelCluster base AMI for a specific ParallelCluster version and OS**. You cannot use an AMI built for one ParallelCluster version with a different version — the cluster will fail validation.

For this reason **we do not publish a prebuilt AMI**. Instead, this page documents the procedure so you can build one against the exact ParallelCluster version and OS you run, and rebuild it whenever you upgrade ParallelCluster.

> When you adopt a new ParallelCluster release, repeat these steps to produce a matching AMI.

## Expected boot time impact

The numbers below are **approximate, order-of-magnitude** figures for the extra time the monitoring setup adds to a compute node's boot. Actual values depend on instance type, region, network, and image sizes — measure in your own environment before drawing conclusions.

| Compute node type | Standard method (post-install runs full install at every boot) | Custom AMI (packages + images pre-baked) |
|---|---|---|
| CPU node | ~60–120 s of extra boot time (docker install, docker-compose download, image pull) | ~5–15 s (only `docker-compose up -d` against cached images) |
| GPU node | ~3–6 min of extra boot time (adds `nvidia-docker2` install, Docker restart, large `dcgm-exporter` image pull) | ~15–40 s |

**Benefits of the custom AMI approach:**

- Compute nodes become ready for Slurm much faster, so jobs start sooner and autoscaling is more responsive.
- No per-boot dependency on external endpoints (GitHub, quay.io, the NVIDIA repo), which removes a class of transient boot failures and rate-limit issues.
- More predictable, repeatable boot times across the fleet.

**Trade-off:** you take on the maintenance of rebuilding the AMI for each ParallelCluster version you upgrade to (see note above).

## Prerequisites

- The [AWS ParallelCluster CLI](https://docs.aws.amazon.com/parallelcluster/latest/ug/install-v3.html) installed, at the **same version** you use to create your cluster. Check with:
  ```bash
  pcluster version
  ```
- Credentials for an account/region where EC2 Image Builder can run (the build launches a temporary EC2 instance).
- The build component script from this repo: [`parallelcluster-setup/build-custom-ami-component.sh`](../parallelcluster-setup/build-custom-ami-component.sh). It installs Docker, `docker-compose`, the `node-exporter` image, and — when it detects NVIDIA hardware on the build instance — `nvidia-docker2` and the `dcgm-exporter` image.

## Step 1 — Find the official ParallelCluster base AMI for your version

The custom AMI must be built on the official ParallelCluster AMI that matches your CLI version and target OS. List the official images:

```bash
pcluster list-official-images --region <your-region> --os alinux2
```

Note the `amiId` (e.g. `ami-0123456789abcdef0`) returned for your OS — you'll use it as the `ParentImage` in the next step. (You can also pass the Image Builder ARN form if you prefer.)

> This solution's install script has been tested primarily on **Amazon Linux 2 (`alinux2`)**.

## Step 2 — Choose how to reference the build component script

The build configuration references the component script by an `https` or `s3` URL.

- **Simplest:** reference the raw file directly from this repository:
  ```
  https://raw.githubusercontent.com/aws-samples/aws-parallelcluster-monitoring/main/parallelcluster-setup/build-custom-ami-component.sh
  ```
- **Recommended for production / pinned builds:** upload a copy to your own S3 bucket so the build is reproducible and not affected by upstream changes:
  ```bash
  aws s3 cp parallelcluster-setup/build-custom-ami-component.sh \
    s3://<your-bucket>/pcluster/build-custom-ami-component.sh
  ```
  Then reference `s3://<your-bucket>/pcluster/build-custom-ami-component.sh`. If you use an S3 URL, make sure the build instance role can read that object (see `Iam / AdditionalIamPolicies` in the build config).

## Step 3 — Create the build-image configuration file

Create `build-image-config.yaml`. Replace `ParentImage` with the AMI ID from Step 1 and set `InstanceType` appropriately.

For a **CPU** compute-node AMI:

```yaml
Build:
  InstanceType: c5.xlarge
  ParentImage: ami-0123456789abcdef0   # from: pcluster list-official-images
  UpdateOsPackages:
    Enabled: false
  Components:
    - Type: script
      Value: https://raw.githubusercontent.com/aws-samples/aws-parallelcluster-monitoring/main/parallelcluster-setup/build-custom-ami-component.sh
```

For a **GPU** compute-node AMI, build on a GPU instance so the component installs the NVIDIA container runtime and pre-pulls `dcgm-exporter`. You can also let ParallelCluster install the NVIDIA GPU driver/CUDA for you:

```yaml
Build:
  InstanceType: g4dn.xlarge
  ParentImage: ami-0123456789abcdef0   # from: pcluster list-official-images
  UpdateOsPackages:
    Enabled: false
  Installation:
    NvidiaSoftware:
      Enabled: true                    # installs the NVIDIA GPU driver + CUDA
  Components:
    - Type: script
      Value: https://raw.githubusercontent.com/aws-samples/aws-parallelcluster-monitoring/main/parallelcluster-setup/build-custom-ami-component.sh
```

> If you reference the script from your own S3 bucket, add a policy that allows the build instance to read it, e.g.:
> ```yaml
>   Iam:
>     AdditionalIamPolicies:
>       - Policy: arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
> ```

## Step 4 — Build the image

```bash
pcluster build-image \
  --image-id monitoring-compute-alinux2 \
  --image-configuration build-image-config.yaml \
  --region <your-region>
```

Building takes up to ~1 hour (EC2 Image Builder provisions an instance, runs the component, creates the AMI, then launches and tests it).

Monitor progress:

```bash
# Overall status
pcluster describe-image --image-id monitoring-compute-alinux2 --region <your-region>

# Tail build logs
pcluster list-image-log-streams --image-id monitoring-compute-alinux2 --region <your-region>
pcluster get-image-log-events --image-id monitoring-compute-alinux2 \
  --log-stream-name <stream-name> --region <your-region>
```

When the status is `BUILD_COMPLETE`, `describe-image` returns the new `amiId`. Note it for the next step.

## Step 5 — Reference the custom AMI in your cluster configuration

Point your compute queues at the custom AMI with `Image / CustomAmi`. You can set it per queue (recommended, so the head node keeps the official AMI) or globally.

```yaml
Scheduling:
  Scheduler: slurm
  SlurmQueues:
    - Name: queue0
      Image:
        CustomAmi: ami-0abc123customami456   # the amiId from Step 4
      ComputeResources:
        - Name: queue0-compute-resource-0
          Instances:
            - InstanceType: c5n.large
          MinCount: 0
          MaxCount: 4
      # ... keep your existing Networking / Iam / CustomActions ...
```

Keep the existing `OnNodeConfigured` post-install action in place. With the custom AMI:

- `yum install docker` / `yum install nvidia-docker2` become fast no-ops because the packages are already present.
- `docker-compose up -d` starts the containers from the **pre-pulled images** instead of downloading them.

That combination is where the boot-time savings come from.

### Optional: trim the boot script further

If you want to squeeze out the last few seconds, you can maintain a slimmed-down variant of `install-monitoring.sh` for pre-baked AMIs that skips the package installation and `docker-compose` download entirely and only runs `docker-compose up -d`. This is optional — the standard script already benefits from the cached packages and images.

## Maintenance reminder

Custom AMIs are pinned to a ParallelCluster version. **Each time you upgrade the ParallelCluster CLI**, rebuild the AMI (repeat Steps 1–4 with the new version's base image) and update `CustomAmi` in your cluster config. Otherwise cluster creation/update will fail validation because of the version mismatch.

## References

- [Building a custom AWS ParallelCluster AMI](https://docs.aws.amazon.com/parallelcluster/latest/ug/building-custom-ami-v3.html)
- [AWS ParallelCluster AMI customization](https://docs.aws.amazon.com/parallelcluster/latest/ug/custom-ami-v3.html)
- [`pcluster build-image` command reference](https://docs.aws.amazon.com/parallelcluster/latest/ug/pcluster.build-image-v3.html)
- [Build section reference](https://docs.aws.amazon.com/parallelcluster/latest/ug/Build-v3.html)
