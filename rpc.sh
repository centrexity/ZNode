#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo 'Usage: znode-rpc METHOD [PARAMS_JSON]' >&2
    exit 2
fi
cookie=/config/rpc/.cookie
if [[ ! -s "$cookie" ]]; then
    echo 'RPC cookie is not available yet; check the Zakura startup log.' >&2
    exit 1
fi
request=$(jq -cn --arg method "$1" --argjson params "${2:-[]}" \
    '{jsonrpc:"2.0",id:"znode",method:$method,params:$params}')
printf '%s' "$request" | curl --silent --show-error --fail-with-body \
    --connect-timeout 3 --max-time "${ZEC_RPC_TIMEOUT:-30}" \
    --user "$(cat "$cookie")" --header 'Content-Type: application/json' \
    --data-binary @- http://127.0.0.1:8232/
