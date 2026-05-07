#!/bin/bash
# shellcheck disable=SC2154  # cfn_* / stack_name vars come from /etc/parallelcluster/cfnconfig
#
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# ParallelCluster OnNodeConfigured post-install entrypoint.
#
# Usage: post-install.sh [version_tag]
#   version_tag: git tag of aws-parallelcluster-monitoring to install.
#                Defaults to the most recent stable release.
#
set -euo pipefail

# shellcheck disable=SC1091
. /etc/parallelcluster/cfnconfig

VERSION="${1:-v1.0}"
MONITORING_DIR_NAME="aws-parallelcluster-monitoring"
TARBALL_URL="https://github.com/aws-samples/${MONITORING_DIR_NAME}/archive/refs/tags/${VERSION}.tar.gz"
MONITORING_HOME="/home/${cfn_cluster_user}/${MONITORING_DIR_NAME}"
LOG_FILE="/var/log/parallelcluster-monitoring-install.log"

# Fetch once; every node type needs the installer tree.
mkdir -p "${MONITORING_HOME}"
curl -fsSL "${TARBALL_URL}" -o "/tmp/${MONITORING_DIR_NAME}.tar.gz"
tar xzf "/tmp/${MONITORING_DIR_NAME}.tar.gz" -C "${MONITORING_HOME}" --strip-components 1
rm -f "/tmp/${MONITORING_DIR_NAME}.tar.gz"

chown -R "${cfn_cluster_user}:${cfn_cluster_user}" "${MONITORING_HOME}"

# Hand off to the OS-aware installer.
bash -x "${MONITORING_HOME}/installer/install.sh" >"${LOG_FILE}" 2>&1
rc=$?
if [[ ${rc} -ne 0 ]]; then
    echo "monitoring install failed; see ${LOG_FILE}" >&2
fi
exit "${rc}"
