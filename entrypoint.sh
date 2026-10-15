#!/bin/bash
set -euo pipefail
umask 077

PUID="${PUID:-99}"
PGID="${PGID:-100}"
ZEC_NETWORK="${ZEC_NETWORK:-mainnet}"
ZEC_MINER_ADDRESS="${ZEC_MINER_ADDRESS:-}"

if [[ ! "$PUID" =~ ^[0-9]+$ || ! "$PGID" =~ ^[0-9]+$ ]] ||
   (( 10#$PUID == 0 || 10#$PGID == 0 )); then
    echo 'PUID and PGID must be positive numeric IDs.' >&2
    exit 1
fi
case "$ZEC_NETWORK" in
    mainnet) network=Mainnet; p2p_port=8233 ;;
    testnet) network=Testnet; p2p_port=18233 ;;
    *) echo 'ZEC_NETWORK must be mainnet or testnet.' >&2; exit 1 ;;
esac
if [[ -n "$ZEC_MINER_ADDRESS" && ! "$ZEC_MINER_ADDRESS" =~ ^[a-zA-Z0-9]+$ ]]; then
    echo 'ZEC_MINER_ADDRESS must be a Zcash address without whitespace or punctuation.' >&2
    exit 1
fi

groupmod -o -g "$PGID" zebra
usermod -o -u "$PUID" -g "$PGID" zebra
install -d -m 750 -o "$PUID" -g "$PGID" /zcash /config /config/cloudflared
install -d -m 700 -o "$PUID" -g "$PGID" /config/rpc /run/znode

if [[ ! -e /config/zebrad.toml ]]; then
    generated_config=$(mktemp /config/.zebrad.toml.XXXXXX)
    trap 'rm -f -- "$generated_config"' EXIT
    cat > "$generated_config" <<EOF
[network]
network = "$network"
listen_addr = "0.0.0.0:$p2p_port"
cache_dir = "/zcash"

[state]
cache_dir = "/zcash"

[rpc]
listen_addr = "127.0.0.1:8232"
enable_cookie_auth = true
cookie_dir = "/config/rpc"

[tracing]
use_color = false
EOF
    if [[ -n "$ZEC_MINER_ADDRESS" ]]; then
        printf '\n[mining]\nminer_address = "%s"\n' "$ZEC_MINER_ADDRESS" >> "$generated_config"
    fi
    chown "$PUID:$PGID" "$generated_config"
    chmod 600 "$generated_config"
    mv -- "$generated_config" /config/zebrad.toml
    trap - EXIT
fi
chown "$PUID:$PGID" /config/zebrad.toml
chmod 600 /config/zebrad.toml

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
    echo 'Cloudflare token missing; Zebra will sync without a tunnel.'
fi
unset CLOUDFLARE_TUNNEL_TOKEN

exec /usr/bin/supervisord -n -c /etc/znode-supervisord.conf
