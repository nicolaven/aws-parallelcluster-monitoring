#!/bin/bash
#
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Shared helpers and pinned versions for the monitoring installer.
# Sourced by installer/install.sh and installer/os/*.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned upstream versions.
# Bump these deliberately; do not use floating tags like "latest".
# ---------------------------------------------------------------------------
readonly SLURM_EXPORTER_VERSION="1.8.0"
readonly SLURM_EXPORTER_REPO="rivosinc/prometheus-slurm-exporter"

# Container image tags (used by compose files via env substitution).
export GRAFANA_IMAGE="grafana/grafana:11.2.2"
export PROMETHEUS_IMAGE="prom/prometheus:v3.1.0"
export PUSHGATEWAY_IMAGE="prom/pushgateway:v1.11.2"
export NODE_EXPORTER_IMAGE="quay.io/prometheus/node-exporter:v1.9.0"
export NGINX_IMAGE="nginx:1.27-alpine"
export DCGM_EXPORTER_IMAGE="nvcr.io/nvidia/k8s/dcgm-exporter:4.0.0-4.0.0-ubuntu22.04"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()  { printf '[monitoring-install] %s\n' "$*"; }
warn() { printf '[monitoring-install][WARN] %s\n' "$*" >&2; }
die()  { printf '[monitoring-install][ERROR] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# OS detection. Writes to global OS_ID and OS_VERSION_ID.
# ---------------------------------------------------------------------------
detect_os() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found, cannot detect OS"
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    export OS_ID OS_VERSION_ID
    log "Detected OS: ${OS_ID} ${OS_VERSION_ID}"
}

# Pick the right OS-specific install script. Returns path or empty.
pick_os_script() {
    local dir="$1"
    case "${OS_ID}:${OS_VERSION_ID}" in
        amzn:2)            echo "${dir}/alinux2.sh" ;;
        amzn:2023)         echo "${dir}/alinux2023.sh" ;;
        ubuntu:22.04)      echo "${dir}/ubuntu22.sh" ;;
        ubuntu:24.04)      echo "${dir}/ubuntu24.sh" ;;
        rhel:9*|rocky:9*|almalinux:9*|centos:9*) echo "${dir}/rhel9.sh" ;;
        *) echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# Detect CPU arch for downloading the right exporter binary.
# ---------------------------------------------------------------------------
detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) die "Unsupported CPU arch: $(uname -m)" ;;
    esac
}

# ---------------------------------------------------------------------------
# Detect GPU instances by checking for an NVIDIA device, not by parsing the
# instance-type string. Works for current and future GPU families.
# ---------------------------------------------------------------------------
has_nvidia_gpu() {
    lspci 2>/dev/null | grep -qi 'nvidia' && return 0
    [[ -e /dev/nvidia0 ]] && return 0
    return 1
}


# ---------------------------------------------------------------------------
# IMDSv2-compatible metadata fetch. ParallelCluster sets Imds.Secured=True
# by default, which requires a session token.
# ---------------------------------------------------------------------------
imds_get() {
    local path="$1"
    local token body http_code curl_err attempt
    curl_err=$(mktemp)
    # Retry the token PUT — IMDS can be briefly unavailable during very
    # early boot, especially on freshly-launched instances.
    for attempt in 1 2 3 4 5; do
        token=$(curl -sS --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>"${curl_err}")
        if [[ -n "${token}" ]]; then
            break
        fi
        warn "IMDSv2 token PUT attempt ${attempt}/5 returned empty for path=${path} (curl: $(cat "${curl_err}"))"
        sleep 2
    done
    rm -f "${curl_err}"
    if [[ -z "${token}" ]]; then
        return 1
    fi
    # Use -w to capture the HTTP status and fail cleanly on 404 (e.g. when
    # asking for public-hostname on a private-subnet instance, IMDS returns
    # an XML error page with 404 which must NOT be treated as a hostname).
    body=$(curl -sS -o /dev/stdout -w "\n%{http_code}" \
        -H "X-aws-ec2-metadata-token: ${token}" \
        "http://169.254.169.254/latest/meta-data/${path}" 2>/dev/null)
    http_code="${body##*$'\n'}"
    body="${body%$'\n'"${http_code}"}"
    if [[ "${http_code}" != "200" ]]; then
        return 1
    fi
    printf '%s' "${body}"
}

# ---------------------------------------------------------------------------
# Install rivosinc prometheus-slurm-exporter from a prebuilt release.
# Replaces the old "go build from vpenso fork" flow.
# ---------------------------------------------------------------------------
install_slurm_exporter() {
    local arch tmpdir url
    arch="$(detect_arch)"
    tmpdir="$(mktemp -d)"
    url="https://github.com/${SLURM_EXPORTER_REPO}/releases/download/v${SLURM_EXPORTER_VERSION}/prometheus-slurm-exporter_linux_${arch}.tar.gz"

    log "Downloading prometheus-slurm-exporter ${SLURM_EXPORTER_VERSION} (${arch})"
    curl -fsSL "${url}" -o "${tmpdir}/exporter.tar.gz"
    tar -xzf "${tmpdir}/exporter.tar.gz" -C "${tmpdir}"
    install -m 0755 "${tmpdir}/prometheus-slurm-exporter" /usr/bin/prometheus-slurm-exporter
    rm -rf "${tmpdir}"

    log "Installing slurm_exporter systemd unit"
    install -m 0644 "${MONITORING_HOME}/prometheus-slurm-exporter/slurm_exporter.service" \
        /etc/systemd/system/slurm_exporter.service
    systemctl daemon-reload
    systemctl enable slurm_exporter
    systemctl restart slurm_exporter
}

# ---------------------------------------------------------------------------
# Verify that "docker" and "docker compose" (v2) both work.
# ---------------------------------------------------------------------------
verify_docker() {
    docker --version >/dev/null 2>&1 || die "docker not installed"
    docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin not installed"
    log "docker: $(docker --version)"
    log "compose: $(docker compose version --short)"
}
