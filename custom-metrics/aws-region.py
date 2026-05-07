#!/usr/bin/env python3
#
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Print the long, human-readable AWS region description for a region code.
# Used by the cost scrapers to build AWS Pricing API filters.
#
import json
import sys
from pathlib import Path

import botocore


def region_description(region_code: str) -> str | None:
    endpoints_file = Path(botocore.__file__).parent / "data" / "endpoints.json"
    with endpoints_file.open() as fh:
        data = json.load(fh)
    for partition in data.get("partitions", []):
        region = partition.get("regions", {}).get(region_code)
        if region:
            return region.get("description")
    return None


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: aws-region.py <region-code>")
    desc = region_description(sys.argv[1])
    if desc is None:
        sys.exit(f"region not found: {sys.argv[1]}")
    print(desc)
