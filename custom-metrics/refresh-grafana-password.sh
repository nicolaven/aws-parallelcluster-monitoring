#!/bin/bash
#
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Fetches the per-cluster Grafana admin password from SSM Parameter Store
# and writes it to a file that the Grafana container mounts via
# GF_SECURITY_ADMIN_PASSWORD__FILE.
#
# This lets us rotate the password in SSM without touching the container:
# the next refresh tick picks up the new value, and Grafana re-reads the
# file on next startup (or we can restart grafana to force immediate pickup).
#
set -euo pipefail

# shellcheck source=/dev/null
. /etc/parallelcluster/cfnconfig

: "${stack_name:?stack_name not set}"
: "${cfn_region:?cfn_region not set}"

SECRET_DIR="/run/grafana-secrets"
SECRET_FILE="${SECRET_DIR}/admin-password"
SSM_PARAM="/parallelcluster/${stack_name}/grafana/admin-password"

mkdir -p "${SECRET_DIR}"
chmod 0750 "${SECRET_DIR}"

password=$(aws ssm get-parameter \
    --region "${cfn_region}" \
    --name "${SSM_PARAM}" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text 2>/dev/null) || {
    echo "ERROR: cannot read SSM parameter ${SSM_PARAM}" >&2
    exit 1
}

# Only update the file if the value actually changed, to avoid spurious
# inotify events / log noise.
if [[ ! -f "${SECRET_FILE}" ]] || [[ "$(cat "${SECRET_FILE}")" != "${password}" ]]; then
    umask 0077
    printf '%s' "${password}" > "${SECRET_FILE}.tmp"
    mv -f "${SECRET_FILE}.tmp" "${SECRET_FILE}"
    # Grafana container reads its own UID (472). Ensure readable.
    chmod 0644 "${SECRET_FILE}"
    echo "Grafana password refreshed from ${SSM_PARAM}"
fi
