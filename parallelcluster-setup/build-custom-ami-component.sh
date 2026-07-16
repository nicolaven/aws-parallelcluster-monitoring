#!/bin/bash
#
#
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# EC2 Image Builder component for aws-parallelcluster-monitoring.
#
# This script is meant to be referenced as a `script` component from a
# ParallelCluster build-image configuration file (see docs/custom-ami.md).
# It runs ONCE, at AMI build time, and pre-installs everything that the
# monitoring stack would otherwise install on every compute node boot:
#   - Docker
#   - docker-compose
#   - the node-exporter container image
#   - (GPU AMIs only) the NVIDIA container runtime and the dcgm-exporter image
#
# The goal is to move all of the slow, network-bound work out of the compute
# node boot path and into the AMI, so that at scale-up the node only has to
# start already-present containers from already-cached images.

set -euo pipefail

# Keep this aligned with the version used in parallelcluster-setup/install-monitoring.sh
DOCKER_COMPOSE_VERSION="1.27.4"

echo "[build-ami] Installing Docker"
yum -y install docker
systemctl enable docker
systemctl start docker

echo "[build-ami] Installing docker-compose ${DOCKER_COMPOSE_VERSION}"
curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

echo "[build-ami] Pre-pulling node-exporter image"
docker pull quay.io/prometheus/node-exporter

# Only relevant when building an AMI intended for GPU compute nodes.
# We detect the NVIDIA hardware on the build instance; build your GPU AMI on a
# GPU instance type (see Build/InstanceType in the build-image config) so this
# branch is taken.
if command -v lspci >/dev/null 2>&1 && lspci | grep -qi nvidia; then
    echo "[build-ami] NVIDIA GPU detected - installing nvidia-docker2 and pre-pulling dcgm-exporter"
    distribution=$(. /etc/os-release; echo "${ID}${VERSION_ID}")
    curl -s -L "https://nvidia.github.io/nvidia-docker/${distribution}/nvidia-docker.repo" \
        | tee /etc/yum.repos.d/nvidia-docker.repo
    yum -y clean expire-cache
    yum -y install nvidia-docker2
    systemctl restart docker
    docker pull nvidia/dcgm-exporter
else
    echo "[build-ami] No NVIDIA GPU detected - skipping GPU components"
fi

echo "[build-ami] Pre-installation complete"
