#!/bin/bash
set -euo pipefail
image="${1:-znode:test}"
test_id="znode-smoke-$$"
container="$test_id"
data_volume="$test_id-data"
config_volume="$test_id-config"
results="${ZNODE_TEST_RESULTS:-test-results}"
mkdir -p "$results"
cleanup(){
    docker logs "$container" > "$results/startup.log" 2>&1 || true
    docker rm -fv "$container" >/dev/null 2>&1 || true
    docker volume rm "$data_volume" "$config_volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker volume create "$data_volume" >/dev/null
docker volume create "$config_volume" >/dev/null
docker run -d --name "$container" --network none \
    --sysctl net.ipv4.tcp_slow_start_after_idle=0 \
    -v "$data_volume:/zcash" -v "$config_volume:/config" "$image" >/dev/null
for ((attempt=0; attempt<30; attempt++)); do
    if docker exec "$container" test -s /config/zakura.toml; then
        break
    fi
    sleep 1
done
docker cp "$container:/config/zakura.toml" "$results/generated-mainnet.toml"
docker exec "$container" python3 -c '
import tomllib
with open("/config/zakura.toml", "rb") as config_file:
    config = tomllib.load(config_file)
assert config["network"]["network"] == "Mainnet"
assert config["state"]["cache_dir"] == "/zcash/zakura"
assert config["state"]["storage_mode"]["pruned"]["tx_retention"] == 10000
assert config["rpc"]["listen_addr"] == "127.0.0.1:8232"
assert config["rpc"]["enable_cookie_auth"] is True
assert config["rpc"]["cookie_dir"] == "/config/rpc"
'
# The production-config probe has no network and can be stuck discovering seeds.
# Its scratch state is disposable; restart only the Regtest phase gracefully.
docker kill "$container" >/dev/null
docker cp tests/regtest.toml "$container:/config/zakura.toml"
docker start "$container" >/dev/null

wait_for_rpc(){
    for ((attempt=0; attempt<60; attempt++)); do
        if docker exec "$container" znode-healthcheck >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo 'Zakura RPC did not become ready.' >&2
    return 1
}
wait_for_rpc
docker exec "$container" znode-rpc getinfo > "$results/getinfo.json"
jq -e '.error == null and (.result | type == "object")' "$results/getinfo.json" >/dev/null
for credential in missing invalid; do
    auth_args=()
    if [[ "$credential" == invalid ]]; then auth_args=(--user invalid:invalid); fi
    auth_status=0
    unauthenticated=$(docker exec "$container" curl --silent \
        --output /run/znode/unauthenticated.body --max-time 5 \
        --write-out '%{http_code}' "${auth_args[@]}" \
        --header 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","id":1,"method":"getinfo","params":[]}' \
        http://127.0.0.1:8232/) || auth_status=$?
    if [[ "$unauthenticated:$auth_status" == 000:52 ]]; then
        # Some compatible releases drop unauthorized connections instead of sending 401.
        docker exec "$container" test ! -s /run/znode/unauthenticated.body
    else
        test "$unauthenticated:$auth_status" = 401:0
    fi
done
docker exec "$container" bash -c \
    'test "$(stat -c %u:%g /zcash)" = 99:100 && test "$(stat -c %a /config/rpc/.cookie)" = 600'
docker top "$container" -eo pid,uid,comm > "$results/processes.txt"
awk '$2 == 99 && $3 == "zakurad" { found = 1 } END { exit !found }' "$results/processes.txt"
if awk '$3 == "cloudflared" { found = 1 } END { exit !found }' "$results/processes.txt"; then
    echo 'Cloudflared started without a tunnel token.' >&2
    exit 1
fi
first_cookie=$(docker exec "$container" sha256sum /config/rpc/.cookie)
first_config=$(docker exec "$container" sha256sum /config/zakura.toml)
docker restart --time 120 "$container" >/dev/null
wait_for_rpc
second_cookie=$(docker exec "$container" sha256sum /config/rpc/.cookie)
second_config=$(docker exec "$container" sha256sum /config/zakura.toml)
test "$first_cookie" != "$second_cookie"
test "$first_config" = "$second_config"
echo 'PASS: startup, authenticated RPC, non-root daemon, cookie rotation, persistent config, and tunnel-free restart'
