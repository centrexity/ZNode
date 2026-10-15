# ZNode

Zcash node for Unraid using prebuilt Zakura 1.6.0 and Cloudflare Tunnel
2026.10.0. Native pruning retains **12,000 finalized block bodies** by default.
The image extends the official `zakuracore/zakura` Debian runtime: no custom
node compilation, source patches, or snapshot download is required.

## Unraid

| Setting | Value |
| --- | --- |
| Repository | `ghcr.io/centrexity/znode:latest` (`:main` is also published) |
| Network | Bridge |
| Data volume | `/mnt/user/appdata/znode/data` -> `/zcash` |
| Config volume | `/mnt/user/appdata/znode/config` -> `/config` |
| Extra Parameters | `--stop-timeout=130 --sysctl net.ipv4.tcp_slow_start_after_idle=0` |
| Host port mappings | None |

Start the container once. It generates `/config/zakura.toml` and begins syncing
with outbound peers. It starts without a tunnel token. Use separate data/config
volumes and a separate container to run Testnet alongside Mainnet.

## Pruning and Storage

The managed configuration is:

```toml
[state]
cache_dir = "/zcash/zakura"

[state.storage_mode.pruned]
tx_retention = 12000
```

Zakura downloads and validates history while discarding eligible transaction
bodies. It retains historical headers, indexes, UTXOs, nullifiers, and other
validation state. The non-finalized reorganization window is additional to the
12,000 finalized blocks. This is a block-count setting, not a total disk quota.

The inspected official 10,000-block snapshot contained 14.12 GB of database
files; only about 450 MB was transaction SST storage. The exact size with
12,000 blocks depends on their transactions. Initially allow 25-30 GB of free
space for data and working headroom, then monitor actual use; that is an estimate,
not a certified peak or a fixed limit. Container images and logs also use space.

`ZEC_PRUNE_KEEP_BLOCKS` defaults to `12000` and is applied on every startup,
including to existing configs. Mainnet/Testnet values below `10000` are rejected.
Do not set native `ZAKURA_`/`ZEBRA_` environment overrides for the managed storage
mode, state cache path, or RPC security settings. Increasing retention cannot
restore bodies that have already been pruned.

## Updating From Zebra

Keep the same Unraid repository and volume mappings, and use Force Update.
On first startup the wrapper imports `/config/zebrad.toml` into the new
`/config/zakura.toml`, preserving network/miner settings and the original file.
It enforces native pruning and private cookie-authenticated RPC. Comments are
preserved; an existing native config changed by the wrapper is backed up once
as `/config/zakura.toml.before-znode-pruning`.

The new database uses `/zcash/zakura`, separate from the old Zebra cache.
**Old data is not deleted or automatically imported. The new node syncs afresh.**
The old database still consumes disk space until you separately remove it after
checking what you need. Do not assume that changing images frees its storage.
Stop the node and back up needed configuration before updating.

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
this container, which shares Zakura's network namespace.

## RPC Authentication

Zakura requires HTTP Basic authentication with the contents of
`/config/rpc/.cookie`. Keep that file and the tunnel token private. Zakura
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
clients. Send Basic credentials preemptively rather than relying on an HTTP 401
challenge; compatible node releases can close unauthorized connections instead.
The health check verifies authenticated RPC availability, not completion of sync.

## Configuration and Mining

| Variable | Default | Purpose |
| --- | --- | --- |
| `PUID` | `99` | Non-root node user ID |
| `PGID` | `100` | Node group ID |
| `ZEC_NETWORK` | `mainnet` | `mainnet` or `testnet` |
| `ZEC_MINER_ADDRESS` | unset | Optional Zcash payout address for mining templates |
| `ZEC_PRUNE_KEEP_BLOCKS` | `12000` | Retained finalized block bodies, minimum `10000` |
| `CLOUDFLARE_TUNNEL_TOKEN` | unset | Optional alternative to the token file |

Network and mining settings generate the config only on first start. To change
them later, stop the container and edit `/config/zakura.toml`. Keep its RPC
listener at `127.0.0.1:8232`, authentication enabled, and cookie directory at
`/config/rpc` so the helper, health check, and tunnel continue to work. Changing
PUID/PGID for existing data requires updating ownership of that data while the
container is stopped; startup does not recursively walk a large blockchain.

Zakura supports `getblocktemplate` and `submitblock`. To fetch usable mining work,
first configure your own Zcash payout address under `[mining]` as `miner_address`
and wait for sync to finish. This container runs the node, not a miner or wallet.

Historical block bodies and transactions outside the retention window are not
available through RPC. In upstream 1.6.0, `gettxout` also depends on the original
transaction body: an old pruned transaction can return null even if its output
is unspent. `getaddressutxos` can still report retained unspent outputs for known
transparent addresses. Do not treat the pruned node as an archival wallet backend.

## Build and Verification

```sh
docker build -t znode:test .
bash tests/smoke.sh znode:test
docker run --rm --network none --entrypoint python3 -v "$PWD/tests:/tests:ro" znode:test /tests/config_test.py
bash tests/pruning.sh znode:test
```

The test overrides the runtime network to isolated Regtest, with external
networking disabled, while checking the generated production config. It verifies
authenticated RPC, rejection of unauthenticated requests, non-root execution,
cookie rotation on restart, and config persistence. It removes its own container
and volumes and retains logs in `test-results/`. It does not download the chain
or prove that the node is fully synced. GitHub Actions runs this test before
publishing `latest`, `main`, and a commit-specific image tag for Linux amd64.
Additional tests verify config migration and 12,000-block native retention by
mining past its boundary, checking old UTXOs through the address index, retaining
headers/hashes, performing a recent reorganization, and mining after restart.

Update the pinned Zakura version as supported releases are published; node
releases have end-of-support limits. A public GitHub repository can still have
a private GHCR package: if Unraid cannot pull, open the package settings and
change its visibility to public.

## Upstream Documentation

- [Zcashd end of life](https://zcash.github.io/zcash/user/end-of-life.html)
- [Official Zakura downloads and Docker images](https://zakura.com/download/)
- [Zakura configuration and pruning](https://github.com/zakura-core/zakura/blob/v1.6.0/crates/zakura-state/src/config.rs)
- [Mainnet pruning example](https://github.com/zakura-core/zakura/blob/v1.6.0/deploy/runner/zakura-bench-mainnet-config.toml)
- [Zakura mining RPC](https://github.com/zakura-core/zakura/blob/v1.6.0/docs/zcashd-compat.md#mining-zakura-is-canonical)
