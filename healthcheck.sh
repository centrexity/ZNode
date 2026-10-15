#!/bin/bash
set -euo pipefail
ZEC_RPC_TIMEOUT=5 /usr/local/bin/znode-rpc getinfo |
    jq -e '.error == null and (.result | type == "object")' >/dev/null
