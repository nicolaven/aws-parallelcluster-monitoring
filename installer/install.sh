#!/bin/bash
# shellcheck disable=SC2154  # cfn_* / stack_name vars come from /etc/parallelcluster/cfnconfig
#
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Main OS-aware installer. Sourced/run by post-install.sh on the
# ParallelCluster HeadNode and ComputeFleet nodes.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=installer/common.sh
. "${SCRIPT_DIR}/common.sh"

# Source ParallelCluster environment (cfn_node_type, cfn_cluster_user, cfn_region, ...).
[[ -r /etc/parallelcluster/cfnconfig ]] || die "/etc/parallelcluster/cfnconfig not found"
# shellcheck disable=SC1091
. /etc/parallelcluster/cfnconfig

: "${cfn_node_type:?cfn_node_type not set}"
: "${cfn_cluster_user:?cfn_cluster_user not set}"
: "${cfn_region:?cfn_region not set}"

MONITORING_DIR_NAME="aws-parallelcluster-monitoring"
MONITORING_HOME="/home/${cfn_cluster_user}/${MONITORING_DIR_NAME}"
export MONITORING_HOME MONITORING_DIR_NAME

log "Node type: ${cfn_node_type}"
log "Monitoring home: ${MONITORING_HOME}"

# ---------------------------------------------------------------------------
# 1. Install docker + compose plugin for this OS.
# ---------------------------------------------------------------------------
detect_os
os_script="$(pick_os_script "${SCRIPT_DIR}/os")"
[[ -n "${os_script}" && -r "${os_script}" ]] \
    || die "Unsupported OS: ${OS_ID} ${OS_VERSION_ID}. Supported: amzn2, amzn2023, ubuntu 22.04/24.04, rhel/rocky/alma/centos-stream 9.x"

log "Running OS bootstrap: ${os_script}"
# shellcheck disable=SC1090
. "${os_script}"

verify_docker

# ---------------------------------------------------------------------------
# 2. Node-type-specific configuration.
# ---------------------------------------------------------------------------
case "${cfn_node_type}" in

    HeadNode|MasterServer)
        log "Configuring HeadNode"

        # Extract context from chef dna.json and CloudFormation.
        cfn_fsx_fs_id=$(jq -r '.cfn_fsx_fs_id // ""' /etc/chef/dna.json 2>/dev/null || echo "")
        master_instance_id=$(imds_get instance-id)
        [[ -n "${master_instance_id}" ]] || die "Failed to fetch instance-id from IMDSv2"
        s3_bucket=$(echo "${cfn_postinstall:-}" | sed 's|s3://||;s|/.*||')
        cluster_s3_bucket=$(jq -r '.cluster_s3_bucket // ""' /etc/chef/dna.json 2>/dev/null || echo "")
        cluster_config_s3_key=$(jq -r '.cluster_config_s3_key // ""' /etc/chef/dna.json 2>/dev/null || echo "")
        cluster_config_version=$(jq -r '.cluster_config_version // ""' /etc/chef/dna.json 2>/dev/null || echo "")
        log_group_names="\\/aws\\/parallelcluster\\/$(echo "${stack_name}" | cut -d'-' -f2-)"

        if [[ -n "${cluster_s3_bucket}" && -n "${cluster_config_s3_key}" ]]; then
            aws s3api get-object \
                --bucket "${cluster_s3_bucket}" \
                --key "${cluster_config_s3_key}" \
                --region "${cfn_region}" \
                --version-id "${cluster_config_version}" \
                "${MONITORING_HOME}/parallelcluster-setup/cluster-config.json" >/dev/null
        fi

        chown "${cfn_cluster_user}:${cfn_cluster_user}" -R "/home/${cfn_cluster_user}"
        chmod +x "${MONITORING_HOME}/custom-metrics/"*

        cp -rp "${MONITORING_HOME}/custom-metrics/"* /usr/local/bin/

        # Cron jobs for the cost scraper. MAILTO="" prevents cron email spam
        # (closes issue #15).
        crontab -u "${cfn_cluster_user}" -l 2>/dev/null > /tmp/crontab.tmp || true
        {
            echo 'MAILTO=""'
            grep -v -E 'MAILTO|cost-metrics\.sh' /tmp/crontab.tmp || true
            echo '*/1 * * * * /usr/local/bin/1m-cost-metrics.sh >/dev/null 2>&1'
            echo '0 * * * * /usr/local/bin/1h-cost-metrics.sh >/dev/null 2>&1'
        } | crontab -u "${cfn_cluster_user}" -
        rm -f /tmp/crontab.tmp

        # Token replacement in dashboards/config. (Phase 3 will replace all
        # of this with Grafana template variables.)
        sed -i "s/_S3_BUCKET_/${s3_bucket}/g"            "${MONITORING_HOME}/grafana/dashboards/ParallelCluster.json"
        sed -i "s/__INSTANCE_ID__/${master_instance_id}/g" "${MONITORING_HOME}/grafana/dashboards/ParallelCluster.json"
        sed -i "s/__FSX_ID__/${cfn_fsx_fs_id}/g"         "${MONITORING_HOME}/grafana/dashboards/ParallelCluster.json"
        sed -i "s/__AWS_REGION__/${cfn_region}/g"        "${MONITORING_HOME}/grafana/dashboards/ParallelCluster.json"
        sed -i "s/__AWS_REGION__/${cfn_region}/g"        "${MONITORING_HOME}/grafana/dashboards/logs.json"
        sed -i "s/__LOG_GROUP__NAMES__/${log_group_names}/g" "${MONITORING_HOME}/grafana/dashboards/logs.json"
        sed -i "s/__Application__/${stack_name}/g"       "${MONITORING_HOME}/prometheus/prometheus.yml"
        sed -i "s/__AWS_REGION__/${cfn_region}/g"        "${MONITORING_HOME}/prometheus/prometheus.yml"
        sed -i "s/__INSTANCE_ID__/${master_instance_id}/g" "${MONITORING_HOME}/grafana/dashboards/master-node-details.json"
        sed -i "s/__INSTANCE_ID__/${master_instance_id}/g" "${MONITORING_HOME}/grafana/dashboards/compute-node-list.json"
        sed -i "s/__INSTANCE_ID__/${master_instance_id}/g" "${MONITORING_HOME}/grafana/dashboards/compute-node-details.json"
        sed -i "s|__MONITORING_DIR__|${MONITORING_DIR_NAME}|g" "${MONITORING_HOME}/compose/head.yml"

        # Self-signed TLS cert for nginx. (Phase 2 will add an ACM option.)
        nginx_dir="${MONITORING_HOME}/nginx"
        nginx_ssl_dir="${nginx_dir}/ssl"
        mkdir -p "${nginx_ssl_dir}"
        # Prefer public hostname; fall back to private hostname for clusters in private subnets.
        public_hostname=$(imds_get public-hostname)
        [[ -n "${public_hostname}" ]] || public_hostname=$(imds_get hostname)
        [[ -n "${public_hostname}" ]] || public_hostname="localhost"
        echo -e "\nDNS.1=${public_hostname}" >> "${nginx_dir}/openssl.cnf"
        openssl req -new -x509 -nodes -newkey rsa:4096 -days 3650 \
            -keyout "${nginx_ssl_dir}/nginx.key" \
            -out "${nginx_ssl_dir}/nginx.crt" \
            -config "${nginx_dir}/openssl.cnf" >/dev/null 2>&1
        chown -R "${cfn_cluster_user}:${cfn_cluster_user}" "${nginx_ssl_dir}"

        # Start the monitoring stack.
        cd "${MONITORING_HOME}"
        docker compose --env-file /etc/parallelcluster/cfnconfig \
            -f "${MONITORING_HOME}/compose/head.yml" \
            -p monitoring-head up -d

        # Install the slurm exporter (prebuilt binary, no go build).
        install_slurm_exporter
        ;;

    ComputeFleet)
        log "Configuring ComputeFleet node"

        if has_nvidia_gpu; then
            log "NVIDIA GPU detected — installing nvidia-container-toolkit"
            # Replaces deprecated nvidia-docker2.
            case "${OS_ID}" in
                amzn|rhel|rocky|almalinux|centos)
                    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
                        -o /etc/yum.repos.d/nvidia-container-toolkit.repo
                    (dnf -y install nvidia-container-toolkit 2>/dev/null) \
                        || yum -y install nvidia-container-toolkit
                    ;;
                ubuntu|debian)
                    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
                        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
                    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
                        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
                        > /etc/apt/sources.list.d/nvidia-container-toolkit.list
                    apt-get update
                    DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit
                    ;;
            esac
            nvidia-ctk runtime configure --runtime=docker
            systemctl restart docker
            docker compose -f "${MONITORING_HOME}/compose/compute.gpu.yml" \
                -p monitoring-compute up -d
        else
            docker compose -f "${MONITORING_HOME}/compose/compute.yml" \
                -p monitoring-compute up -d
        fi
        ;;

    *)
        warn "Unknown cfn_node_type=${cfn_node_type}, skipping"
        ;;
esac

log "Done."
