#!/bin/bash
set -euo pipefail
umask 077

PUID="${PUID:-99}"
PGID="${PGID:-100}"
ZEC_NETWORK="${ZEC_NETWORK:-mainnet}"
ZEC_MINER_ADDRESS="${ZEC_MINER_ADDRESS:-}"
ZEC_PRUNE_KEEP_BLOCKS="${ZEC_PRUNE_KEEP_BLOCKS:-12000}"
if [[ ! "$ZEC_PRUNE_KEEP_BLOCKS" =~ ^[0-9]{1,9}$ ]] || (( 10#$ZEC_PRUNE_KEEP_BLOCKS < 10000 )); then
    echo 'ZEC_PRUNE_KEEP_BLOCKS must be an integer of at least 10000.' >&2
    exit 1
fi
export ZEC_PRUNE_KEEP_BLOCKS="$((10#$ZEC_PRUNE_KEEP_BLOCKS))"

if [[ ! "$PUID" =~ ^[0-9]+$ || ! "$PGID" =~ ^[0-9]+$ ]] ||
   (( 10#$PUID == 0 || 10#$PGID == 0 )); then
    echo 'PUID and PGID must be positive numeric IDs.' >&2
    exit 1
fi
case "$ZEC_NETWORK" in
    mainnet) network=Mainnet ;;
    testnet) network=Testnet ;;
    *) echo 'ZEC_NETWORK must be mainnet or testnet.' >&2; exit 1 ;;
esac
if [[ -n "$ZEC_MINER_ADDRESS" && ! "$ZEC_MINER_ADDRESS" =~ ^[a-zA-Z0-9]+$ ]]; then
    echo 'ZEC_MINER_ADDRESS must be a Zcash address without whitespace or punctuation.' >&2
    exit 1
fi

groupmod -o -g "$PGID" zebra
usermod -o -u "$PUID" -g "$PGID" zebra
install -d -m 750 -o "$PUID" -g "$PGID" /zcash /zcash/zakura /config /config/cloudflared
install -d -m 700 -o "$PUID" -g "$PGID" /config/rpc /run/znode

python3 /usr/local/lib/znode/prepare_config.py --network "$network"
chown "$PUID:$PGID" /config/zakura.toml
chmod 600 /config/zakura.toml
echo "Native pruning enabled: retain $ZEC_PRUNE_KEEP_BLOCKS finalized blocks."

export ZNODE_TUNNEL_ENABLED=false
if [[ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
    printf '%s\n' "$CLOUDFLARE_TUNNEL_TOKEN" > /run/znode/tunnel-token
    ZNODE_TUNNEL_ENABLED=true
elif [[ -s /config/cloudflared/token ]]; then
    cp -- /config/cloudflared/token /run/znode/tunnel-token
    ZNODE_TUNNEL_ENABLED=true
fi
if [[ "$ZNODE_TUNNEL_ENABLED" == true ]]; then
    chown "$PUID:$PGID" /run/znode/tunnel-token
    chmod 600 /run/znode/tunnel-token
else
    echo 'Cloudflare token missing; Zakura will sync without a tunnel.'
fi
unset CLOUDFLARE_TUNNEL_TOKEN

exec /usr/bin/supervisord -n -c /etc/znode-supervisord.conf
