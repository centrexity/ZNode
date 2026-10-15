#!/bin/bash
set -euo pipefail
image="${1:-znode:pruned-test}"
container="znode-pruning-$$"
results="${ZNODE_TEST_RESULTS:-test-results/pruning}"
mkdir -p "$results"
cleanup(){
    docker logs "$container" > "$results/startup.log" 2>&1 || true
    docker rm -fv "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker create --name "$container" --network none \
    --sysctl net.ipv4.tcp_slow_start_after_idle=0 "$image" >/dev/null
docker cp tests/pruning-regtest.toml "$container:/config/zebrad.toml"
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
outpoint_params=$(jq -cn --arg tx "$old_tx" '[$tx,0]')
rpc gettxout "$outpoint_params" > "$results/utxo-before.json"
jq -e '.error == null and .result != null' "$results/utxo-before.json" >/dev/null
rpc generate '[2105]' > "$results/generated.json"
jq -e '.error == null and (.result | length) == 2105' "$results/generated.json" >/dev/null
rpc getblock '["1",0]' > "$results/pruned-block.json"
jq -e '.error != null and .result == null' "$results/pruned-block.json" >/dev/null
rpc getblockheader '["1"]' > "$results/pruned-header.json"
jq -e '.error != null and .result == null' "$results/pruned-header.json" >/dev/null
rpc getblockhash '[1]' > "$results/retained-hash.json"
test "$(jq -r '.result' "$results/retained-hash.json")" = \
    "$(jq -r '.result[0]' "$results/first-block.json")"
rpc gettxout "$outpoint_params" > "$results/utxo-after.json"
diff <(jq -S '.result | {value,scriptPubKey,coinbase,version}' "$results/utxo-before.json") \
     <(jq -S '.result | {value,scriptPubKey,coinbase,version}' "$results/utxo-after.json")
jq -e '.error == null and .result.confirmations == 2106' "$results/utxo-after.json" >/dev/null
rpc gettxout "$(jq -cn --arg tx "$old_tx" '[$tx,4294967295]')" > "$results/missing-output.json"
jq -e '.error == null and .result == null' "$results/missing-output.json" >/dev/null
rpc getbestblockhash > "$results/tip.json"
tip_params=$(jq -c '[.result]' "$results/tip.json")
rpc invalidateblock "$tip_params" > "$results/invalidated.json"
jq -e '.error == null' "$results/invalidated.json" >/dev/null
rpc getblockcount > "$results/reorg-count.json"
jq -e '.error == null and .result == 2105' "$results/reorg-count.json" >/dev/null
rpc generate '[1]' > "$results/replacement.json"
jq -e '.error == null and (.result | length) == 1' "$results/replacement.json" >/dev/null
# Upstream backs up non-finalized state at five-second intervals.
sleep 6
docker restart --time 120 "$container" >/dev/null
wait_for_rpc
rpc getblockchaininfo > "$results/reopened.json"
jq -e '.error == null and .result.pruned == true and .result.blocks == 2106' "$results/reopened.json" >/dev/null
rpc getblock '["1",0]' > "$results/reopened-pruned-block.json"
jq -e '.error != null' "$results/reopened-pruned-block.json" >/dev/null
rpc gettxout "$outpoint_params" > "$results/reopened-utxo.json"
diff <(jq -S '.result | {value,scriptPubKey,coinbase,version}' "$results/utxo-before.json") \
     <(jq -S '.result | {value,scriptPubKey,coinbase,version}' "$results/reopened-utxo.json")
rpc generate '[1]' > "$results/after-restart.json"
jq -e '.error == null and (.result | length) == 1' "$results/after-restart.json" >/dev/null
docker exec "$container" du -sk /zcash > "$results/regtest-storage-kib.txt"
echo 'PASS: pruning boundary, retained UTXO and block hashes, mining after pruning, recent reorg, and mining after restart'
