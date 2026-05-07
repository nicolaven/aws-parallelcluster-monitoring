#!/bin/bash
# shellcheck disable=SC2154  # cfn_* / stack_name vars come from /etc/parallelcluster/cfnconfig
#
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Hourly cost scraper. Pushes list-price-based cost estimates for HeadNode,
# S3 bucket, FSx filesystem, and attached EBS volumes to the local
# Prometheus pushgateway.
#
# NOTE: This is a list-price estimator, not your actual bill. Phase 3 will
# add a Cost Explorer datasource for real billed cost.
#
set -uo pipefail

# shellcheck disable=SC1091
. /etc/parallelcluster/cfnconfig

export AWS_DEFAULT_REGION="${cfn_region}"
aws_region_long_name=$(python3 /usr/local/bin/aws-region.py "${cfn_region}")
aws_region_long_name=${aws_region_long_name/Europe/EU}

masterInstanceType=$(curl -s http://169.254.169.254/latest/meta-data/instance-type)
masterInstanceId=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
s3_bucket=$(echo "${cfn_postinstall:-}" | sed 's|s3://||;s|/.*||')

#######################################################################
# S3
#######################################################################
if [[ -n "${s3_bucket}" ]]; then
    s3_bytes=$(aws s3api list-objects --bucket "${s3_bucket}" --output json \
        --query "[sum(Contents[].Size)]" 2>/dev/null \
        | sed -n 2p | tr -d ' ' || echo 0)
    s3_size_gb=$(echo "${s3_bytes:-0} / 1024 / 1024 / 1024" | bc)

    # Fixed bug: previous code referenced $VAR (undefined) in the middle branch.
    if [[ ${s3_size_gb} -le 51200 ]]; then
        s3_range=51200
    elif [[ ${s3_size_gb} -le 512000 ]]; then
        s3_range=512000
    else
        s3_range="Inf"
    fi

    s3_cost_gb_month=$(aws --region us-east-1 pricing get-products \
        --service-code AmazonS3 \
        --filters "Type=TERM_MATCH,Field=location,Value=${aws_region_long_name}" \
                  'Type=TERM_MATCH,Field=storageClass,Value=General Purpose' \
        --query 'PriceList[0]' --output text \
        | jq -r --arg endRange "${s3_range}" '.terms.OnDemand | to_entries[] | .value.priceDimensions | to_entries[].value | select(.endRange==$endRange).pricePerUnit.USD')

    s3=$(echo "scale=2; ${s3_cost_gb_month:-0} * ${s3_size_gb:-0} / 720" | bc)
    echo "s3_cost ${s3}" | curl --silent --data-binary @- http://127.0.0.1:9091/metrics/job/cost
fi

#######################################################################
# HeadNode (on-demand list price)
#######################################################################
master_node_h_price=$(aws pricing get-products \
    --region us-east-1 \
    --service-code AmazonEC2 \
    --filters "Type=TERM_MATCH,Field=instanceType,Value=${masterInstanceType}" \
              "Type=TERM_MATCH,Field=location,Value=${aws_region_long_name}" \
              'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
              'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
              'Type=TERM_MATCH,Field=tenancy,Value=Shared' \
              'Type=TERM_MATCH,Field=capacitystatus,Value=UnusedCapacityReservation' \
    --output text \
    --query 'PriceList' \
    | jq -r '.terms.OnDemand | to_entries[] | .value.priceDimensions | to_entries[] | .value.pricePerUnit.USD')

echo "master_node_cost ${master_node_h_price:-0}" \
    | curl --silent --data-binary @- http://127.0.0.1:9091/metrics/job/cost

#######################################################################
# FSx for Lustre
#######################################################################
fsx_id=$(aws cloudformation describe-stacks --stack-name "${stack_name}" --region "${cfn_region}" \
    | jq -r '.Stacks[0].Parameters | map(select(.ParameterKey == "FSXOptions"))[0].ParameterValue // ""' \
    | awk -F ',' '{print $2}')

if [[ -n "${fsx_id}" && "${fsx_id}" != "null" ]]; then
    fsx_summary=$(aws fsx describe-file-systems --region "${cfn_region}" --file-system-ids "${fsx_id}")
    fsx_size_gb=$(echo "${fsx_summary}" | jq -r '.FileSystems[0].StorageCapacity')
    fsx_type=$(echo "${fsx_summary}" | jq -r '.FileSystems[0].LustreConfiguration.DeploymentType')
    fsx_throughput=$(echo "${fsx_summary}" | jq -r '.FileSystems[0].LustreConfiguration.PerUnitStorageThroughput')

    case "${fsx_type}" in
        SCRATCH_1|SCRATCH_2)
            fsx_cost_gb_month=$(aws pricing get-products \
                --region us-east-1 --service-code AmazonFSx \
                --filters "Type=TERM_MATCH,Field=location,Value=${aws_region_long_name}" \
                          'Type=TERM_MATCH,Field=fileSystemType,Value=Lustre' \
                          'Type=TERM_MATCH,Field=throughputCapacity,Value=N/A' \
                --output text --query 'PriceList' \
                | jq -r '.terms.OnDemand | to_entries[] | .value.priceDimensions | to_entries[] | .value.pricePerUnit.USD')
            ;;
        PERSISTENT_1|PERSISTENT_2)
            # PERSISTENT_2 uses the same pricing key shape as PERSISTENT_1
            # but with different throughput tiers (125/250/500/1000 MB/s/TiB).
            fsx_cost_gb_month=$(aws pricing get-products \
                --region us-east-1 --service-code AmazonFSx \
                --filters "Type=TERM_MATCH,Field=location,Value=${aws_region_long_name}" \
                          'Type=TERM_MATCH,Field=fileSystemType,Value=Lustre' \
                          "Type=TERM_MATCH,Field=throughputCapacity,Value=${fsx_throughput}" \
                --output text --query 'PriceList' \
                | jq -r '.terms.OnDemand | to_entries[] | .value.priceDimensions | to_entries[] | .value.pricePerUnit.USD')
            ;;
        *)
            fsx_cost_gb_month=0
            ;;
    esac

    fsx=$(echo "scale=2; ${fsx_cost_gb_month:-0} * ${fsx_size_gb:-0} / 720" | bc)
    echo "fsx_cost ${fsx}" | curl --silent --data-binary @- http://127.0.0.1:9091/metrics/job/cost
fi

#######################################################################
# HeadNode EBS volumes
#######################################################################
ebs_volume_total_cost=0
ebs_volume_ids=$(aws ec2 describe-instances --instance-ids "${masterInstanceId}" \
    | jq -r '.Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId')

for ebs_volume_id in ${ebs_volume_ids}; do
    ebs_info=$(aws ec2 describe-volumes --volume-ids "${ebs_volume_id}")
    # gp3 is the ParallelCluster 3.x default; make sure it's handled.
    ebs_volume_type=$(echo "${ebs_info}" | jq -r '.Volumes[0].VolumeType')
    ebs_volume_size=$(echo "${ebs_info}" | jq -r '.Volumes[0].Size')

    ebs_cost_gb_month=$(aws --region us-east-1 pricing get-products \
        --service-code AmazonEC2 --output text --query 'PriceList' \
        --filters "Type=TERM_MATCH,Field=location,Value=${aws_region_long_name}" \
                  'Type=TERM_MATCH,Field=productFamily,Value=Storage' \
                  "Type=TERM_MATCH,Field=volumeApiName,Value=${ebs_volume_type}" \
        | jq -r '.terms.OnDemand | to_entries[] | .value.priceDimensions | to_entries[] | .value.pricePerUnit.USD')

    ebs_volume_cost=$(echo "scale=2; ${ebs_cost_gb_month:-0} * ${ebs_volume_size:-0} / 720" | bc)
    ebs_volume_total_cost=$(echo "scale=2; ${ebs_volume_total_cost} + ${ebs_volume_cost}" | bc)
done

echo "ebs_master_cost ${ebs_volume_total_cost}" \
    | curl --silent --data-binary @- http://127.0.0.1:9091/metrics/job/cost
