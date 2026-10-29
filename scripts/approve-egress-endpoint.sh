#!/usr/bin/env bash
# Approve a Confluent egress private endpoint on the storage account and wait
# until the Confluent access point reports READY.
set -euo pipefail

: "${STORAGE_ACCOUNT_ID:?}" "${PRIVATE_ENDPOINT_ID:?}" "${ACCESS_POINT_ID:?}" "${ENVIRONMENT_ID:?}"
: "${CONFLUENT_CLOUD_API_KEY:?}" "${CONFLUENT_CLOUD_API_SECRET:?}"

pe_id_lower=$(echo "$PRIVATE_ENDPOINT_ID" | tr '[:upper:]' '[:lower:]')

for attempt in $(seq 1 60); do
  conn=$(az network private-endpoint-connection list --id "$STORAGE_ACCOUNT_ID" -o json |
    python3 -c '
import json, sys
pe = sys.argv[1]
for c in json.load(sys.stdin):
    if c["properties"]["privateEndpoint"]["id"].lower() == pe:
        print(c["id"], c["properties"]["privateLinkServiceConnectionState"]["status"])
        break
' "$pe_id_lower")
  if [[ -n "$conn" ]]; then
    read -r conn_id status <<<"$conn"
    if [[ "$status" == "Pending" ]]; then
      echo "Approving $conn_id"
      az network private-endpoint-connection approve --id "$conn_id" \
        --description "Approved by Terraform for Confluent Tableflow" >/dev/null
    fi
    [[ "$status" == "Approved" || "$status" == "Pending" ]] && break
  fi
  echo "Waiting for private endpoint connection to appear ($attempt/60)"
  sleep 10
done

for attempt in $(seq 1 90); do
  phase=$(curl -s -u "$CONFLUENT_CLOUD_API_KEY:$CONFLUENT_CLOUD_API_SECRET" \
    "https://api.confluent.cloud/networking/v1/access-points/$ACCESS_POINT_ID?environment=$ENVIRONMENT_ID" |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",{}).get("phase",""))')
  echo "Access point $ACCESS_POINT_ID phase: ${phase:-unknown}"
  [[ "$phase" == "READY" ]] && exit 0
  sleep 10
done

echo "Access point $ACCESS_POINT_ID did not become READY" >&2
exit 1
