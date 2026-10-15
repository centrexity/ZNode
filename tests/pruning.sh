#!/bin/bash
set -euo pipefail
image="${1:-znode:test}"
container="znode-native-pruning-$$"
results="${ZNODE_TEST_RESULTS:-test-results/pruning}"
mkdir -p "$results"
cleanup(){
    docker logs "$container" > "$results/startup.log" 2>&1 || true
    docker rm -fv "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker create --name "$container" --network none \
    --sysctl net.ipv4.tcp_slow_start_after_idle=0 "$image" >/dev/null
docker cp tests/regtest.toml "$container:/config/zakura.toml"
docker start "$container" >/dev/null
wait_for_rpc(){
    for ((attempt=0; attempt<60; attempt++)); do
        if docker exec "$container" znode-healthcheck >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    echo 'Pruning test RPC did not start.' >&2
    return 1
}
rpc(){ docker exec -e ZEC_RPC_TIMEOUT=600 "$container" znode-rpc "$@"; }
wait_for_rpc
rpc getblockchaininfo > "$results/before.json"
jq -e '.error == null and .result.pruned == true' "$results/before.json" >/dev/null
rpc generate '[1]' > "$results/first-block.json"
jq -e '.error == null and (.result | length) == 1' "$results/first-block.json" >/dev/null
rpc getblock '["1",1]' > "$results/old-block.json"
old_tx=$(jq -er '.result.tx[0]' "$results/old-block.json")
rpc generate '[11005]' > "$results/generated.json"
jq -e '.error == null and (.result | length) == 11005' "$results/generated.json" >/dev/null
rpc getblockchaininfo > "$results/pruned-info.json"
jq -e '.error == null and .result.pruned == true and .result.blocks == 11006 and (.result.blocks - 1000 - .result.pruneheight + 1) == 10000' "$results/pruned-info.json" >/dev/null
floor=$(jq -er '.result.pruneheight' "$results/pruned-info.json")
rpc getblock "$(jq -cn --arg height "$((floor-1))" '[$height,0]')" > "$results/pruned-block.json"
jq -e '.error != null and .result == null' "$results/pruned-block.json" >/dev/null
rpc getblock "$(jq -cn --arg height "$floor" '[$height,0]')" > "$results/boundary-block.json"
jq -e '.error == null and (.result | type) == "string"' "$results/boundary-block.json" >/dev/null
rpc getblockheader '["1"]' > "$results/retained-header.json"
jq -e '.error == null and .result != null' "$results/retained-header.json" >/dev/null
rpc getblockhash '[1]' > "$results/retained-hash.json"
test "$(jq -r '.result' "$results/retained-hash.json")" = "$(jq -r '.result[0]' "$results/first-block.json")"
address_params='[{"addresses":["t27eWDgjFYJGVXmzrXeVjnb5J3uXDM9xH9v"]}]'
rpc getaddressutxos "$address_params" > "$results/retained-utxos.json"
jq -e --arg tx "$old_tx" '.error == null and any(.result[]; .txid == $tx and .outputIndex == 0)' "$results/retained-utxos.json" >/dev/null
rpc gettxout "$(jq -cn --arg tx "$old_tx" '[$tx,0,false]')" > "$results/upstream-old-gettxout.json"
rpc getbestblockhash > "$results/tip.json"
rpc invalidateblock "$(jq -c '[.result]' "$results/tip.json")" > "$results/invalidated.json"
jq -e '.error == null' "$results/invalidated.json" >/dev/null
rpc getblockcount > "$results/reorg-count.json"
jq -e '.error == null and .result == 11005' "$results/reorg-count.json" >/dev/null
rpc generate '[1]' > "$results/replacement.json"
jq -e '.error == null and (.result | length) == 1' "$results/replacement.json" >/dev/null
sleep 6
docker restart --time 120 "$container" >/dev/null
wait_for_rpc
rpc getblockchaininfo > "$results/reopened.json"
jq -e '.error == null and .result.pruned == true and .result.blocks == 11006' "$results/reopened.json" >/dev/null
rpc getaddressutxos "$address_params" > "$results/reopened-utxos.json"
jq -e --arg tx "$old_tx" '.error == null and any(.result[]; .txid == $tx and .outputIndex == 0)' "$results/reopened-utxos.json" >/dev/null
rpc generate '[1]' > "$results/after-restart.json"
jq -e '.error == null and (.result | length) == 1' "$results/after-restart.json" >/dev/null
docker exec "$container" du -sk /zcash > "$results/regtest-storage-kib.txt"
echo 'PASS: native 10000-block pruning boundary, retained UTXO/header/hash, recent reorg, and mining after restart'
