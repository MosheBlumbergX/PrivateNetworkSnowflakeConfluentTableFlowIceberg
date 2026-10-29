#!/usr/bin/env bash
# Run a local shell script on the demo VM via `az vm run-command` and fail
# unless its output contains the success marker.
# Usage: vm-run.sh <resource-group> <vm-name> <script-file> <marker>
set -euo pipefail

rg=$1 vm=$2 script=$3 marker=$4

out=$(az vm run-command invoke -g "$rg" -n "$vm" --command-id RunShellScript \
  --scripts @"$script" -o json)
msg=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["value"][0]["message"])' <<<"$out")
echo "$msg"
grep -q "$marker" <<<"$msg"
