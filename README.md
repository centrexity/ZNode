# ZNode

Zcash node for Unraid using Zebra 6.4.2 and Cloudflare Tunnel 2026.10.0.
The image extends the official `zfnd/zebra` Debian runtime. Zcashd has reached
end of life, so this deployment uses the supported Zebra implementation.

## Unraid

| Setting | Value |
| --- | --- |
| Repository | `ghcr.io/centrexity/znode:latest` (`:main` is also published) |
| Network | Bridge |
| Data volume | `/mnt/user/appdata/znode/data` -> `/zcash` |
| Config volume | `/mnt/user/appdata/znode/config` -> `/config` |
| Extra Parameters | `--stop-timeout=130 --sysctl net.ipv4.tcp_slow_start_after_idle=0` |
| Host port mappings | None |

Start the container once. It generates `/config/zebrad.toml` and begins syncing
with outbound peers. It starts without a tunnel token. Use separate data/config
volumes and a separate container to run Testnet alongside Mainnet.

Zebra currently has no supported pruning mode. Budget at least 300 GB of disk
space with room to grow, preferably on an SSD. Recommended resources are 4 CPU
cores and 16 GB RAM; the documented minimum RAM is 4 GB.

## Cloudflare Tunnel

1. Create a remotely managed tunnel in Cloudflare Zero Trust.
2. Store only its token in
   `/mnt/user/appdata/znode/config/cloudflared/token`, or supply the Unraid
   environment variable `CLOUDFLARE_TUNNEL_TOKEN`.
3. Configure a public hostname, for example `znode.simoleons.net`, with HTTP
   service URL `http://127.0.0.1:8232`.
4. Restart the container. Cloudflared connects outbound; no router port opening
   is required. This HTTP tunnel carries RPC, not Zcash P2P.

Do not use the Unraid host's loopback address in a separate tunnel container.
The loopback service URL above applies to the cloudflared process included in
this container, which shares Zebra's network namespace.

## RPC Authentication

Zebra requires HTTP Basic authentication with the contents of
`/config/rpc/.cookie`. Keep that file and the tunnel token private. Zebra
generates a new cookie on every daemon start; remote clients must refresh their
credentials after a restart. The cookie is `username:password`, not a permanent
`rpcuser`/`rpcpassword` setting.

To inspect the current credential locally:

```sh
docker exec ZNode cat /config/rpc/.cookie
```

To check the node without displaying credentials:

```sh
docker exec ZNode znode-rpc getinfo
docker exec ZNode znode-rpc getblockchaininfo
```

For a remote request, use HTTPS, POST JSON-RPC to `/`, and authenticate with the
current cookie. Cloudflare Access can additionally limit the hostname to your
clients. Zebra 6.4.2 closes unauthenticated connections without an HTTP response;
curl reports an empty reply, and a tunnel may report a gateway error. Send Basic
credentials preemptively rather than waiting for an HTTP 401 challenge.
The health check verifies authenticated RPC availability, not completion of sync.

## Configuration and Mining

| Variable | Default | Purpose |
| --- | --- | --- |
| `PUID` | `99` | Non-root node user ID |
| `PGID` | `100` | Node group ID |
| `ZEC_NETWORK` | `mainnet` | `mainnet` or `testnet` |
| `ZEC_MINER_ADDRESS` | unset | Optional Zcash payout address for mining templates |
| `CLOUDFLARE_TUNNEL_TOKEN` | unset | Optional alternative to the token file |

Network and mining settings generate the config only on first start. To change
them later, stop the container and edit `/config/zebrad.toml`. Keep its RPC
listener at `127.0.0.1:8232`, authentication enabled, and cookie directory at
`/config/rpc` so the helper, health check, and tunnel continue to work. Changing
PUID/PGID for existing data requires updating ownership of that data while the
container is stopped; startup does not recursively walk a large blockchain.

Zebra supports `getblocktemplate` and `submitblock`. To fetch usable mining work,
first configure your own Zcash payout address under `[mining]` as `miner_address`
and wait for sync to finish. This container runs the node, not a miner or wallet.

## Build and Verification

```sh
docker build -t znode:test .
bash tests/smoke.sh znode:test
```

The test overrides the runtime network to isolated Regtest, with external
networking disabled, while checking the generated production config. It verifies
authenticated RPC, rejection of unauthenticated requests, non-root execution,
cookie rotation on restart, and config persistence. It removes its own container
and volumes and retains logs in `test-results/`. It does not download the chain
or prove that the node is fully synced. GitHub Actions runs this test before
publishing `latest`, `main`, and a commit-specific image tag for Linux amd64.

Update the pinned Zebra version as supported releases are published; Zebra
releases have end-of-support limits. A public GitHub repository can still have
a private GHCR package: if Unraid cannot pull, open the package settings and
change its visibility to public.

## Upstream Documentation

- [Zcashd end of life](https://zcash.github.io/zcash/user/end-of-life.html)
- [Zebra Docker deployment](https://zebra.zfnd.org/user/docker.html)
- [Hardware and storage requirements](https://zebra.zfnd.org/user/requirements.html)
- [Zebra mining and cookie authentication](https://zebra.zfnd.org/user/mining.html)
- [Pruning feature request](https://github.com/ZcashFoundation/zebra/issues/8559)
