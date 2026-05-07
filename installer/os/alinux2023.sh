#!/bin/bash
# shellcheck disable=SC2154  # cfn_* / stack_name vars come from /etc/parallelcluster/cfnconfig
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Amazon Linux 2023 package installation.
set -euo pipefail

log "Installing docker on Amazon Linux 2023"
dnf -y install docker jq bc curl tar

# AL2023 does not ship docker-compose-plugin in its default repos yet.
# Install upstream plugin binary.
COMPOSE_VERSION="v2.29.7"
install -d -m 0755 /usr/libexec/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-$(uname -m)" \
    -o /usr/libexec/docker/cli-plugins/docker-compose
chmod +x /usr/libexec/docker/cli-plugins/docker-compose

systemctl enable docker
systemctl start docker
usermod -a -G docker "${cfn_cluster_user}"
