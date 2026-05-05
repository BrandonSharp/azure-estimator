#!/usr/bin/env bash
set -euo pipefail

parse_bicep_plan() {
  local file="$1"

  jq -r '
    .changes[]
    | select(.changeType=="Create" or .changeType=="Modify")
    | .resource
  ' "$file"
}

extract_vms() {
  jq -r '
    select(.type=="Microsoft.Compute/virtualMachines")
    | {
        type: "vm",
        name: .name,
        size: .properties.hardwareProfile.vmSize,
        os: (.properties.storageProfile.osDisk.osType | ascii_downcase),
        count: 1,
        hours_per_month: 730
      }
  '
}