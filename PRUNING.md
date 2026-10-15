# Experimental ZNode pruning

This branch adds native pruning to pinned Zebra 6.4.2. It is an experimental
validator change, not an upstream-supported feature or a certified 5 GB node.
The normal `latest` and `main` images remain archival.

## Retention rules

`ZEC_PRUNE_KEEP_BLOCKS` sets the number of finalized block payloads to retain.
The minimum and experimental default are 1000. Zebra's additional non-finalized
reorganization window stays in memory and its normal on-disk backup.

Pruning deletes expired transaction bodies and full headers atomically with
finalized block commits. It keeps genesis and the first Sapling/Orchard subtree
reference blocks needed by upstream format checks. Block hashes, transaction
location indexes, unspent outputs, spent-nullifier sets, commitment trees,
anchors, history-tree state, and value-pool totals remain intact. Old block and
header RPC reads report unavailable data. The node does not advertise archival
block service in handshakes or its own peer-address announcements.

Before discarding a transaction with transparent outputs, pruning preserves its
four-byte version in a separate indexed column. `gettxout` uses this metadata
and the retained UTXO instead of requiring the deleted transaction body. This
keeps values, scripts, coinbase status, version, and confirmations accurate;
it does not recreate transaction bodies for historical RPC requests.

Manual RocksDB compaction runs periodically and on restart to reclaim expired
payload SST storage. Compaction needs temporary disk space and can delay sync.
The retained block count is not a hard byte quota.

## Separate database

Pruned state lives under `/zcash/znode-pruned-v1/state/v28/<network>`, separate
from the official archival database. Non-finalized backups also live under
`/zcash/znode-pruned-v1/`. Use separate data and config volumes when
testing. Turning off pruning does not restore deleted data; an archival node
must sync its own database. Automatic format upgrades/downgrades are rejected
for experimental state, because some upstream migrations require full history.
Indexer and Elasticsearch builds cannot enable this pruning mode.

## The 5 GB target

Five GB may hold a useful recent transaction window, but it is not a verified
total-node budget. Unspent outputs and nullifiers from old transactions cannot
be deleted just because they are old. Their state, indexes, tree history, the
recent payload window, database/WAL overhead, and compaction headroom all count.
Passing the small Regtest test does not establish Mainnet's storage footprint.
No code stops consensus validation from retaining required data to meet a quota.

Before deploying on a 5 GB allocation, complete a pruned Mainnet sync on a
larger test volume, measure peak as well as steady disk usage, and compare the
chain tip and accepted/rejected transactions with an unmodified node. That
qualification is not replaced by the included tests. This implementation still
downloads and verifies historical blocks; it discards eligible data afterwards.

## Build and test

```sh
docker build -f Dockerfile.pruned -t znode:pruned-test .
bash tests/smoke.sh znode:pruned-test
bash tests/pruning.sh znode:pruned-test
```

The source patch is pinned to upstream commit
`e3eef2f37c35127ad1769f19a1ebc7eaa5d5d291`. Unit tests commit real Mainnet
fixture blocks and check retained validation columns, UTXOs, range boundaries,
compaction, and reopening. The node integration test mines past the pruning
boundary on isolated Regtest, checks that an old unspent output survives,
performs a recent reorganization, and resumes mining after restart.

Only a passing experimental workflow publishes
`ghcr.io/centrexity/znode:pruned-experimental`. It does not replace stable tags.

### Local verification (2026-10-15 UTC)

- Rust 1.91.0: five state pruning tests and one peer-advertisement test passed.
- The daemon built with `default-release-binaries` features, without compiler warnings.
- The local debug-profile daemon passed Docker authentication/restart smoke tests.
- Isolated Regtest mined 2106 blocks, removed old bodies and headers, retained
  hashes and an old UTXO with exact script/value/version and 2106 confirmations,
  replaced the best block, reopened its database, and mined another block.
- The disposable Regtest data volume used 7076 KiB after that test. This is a
  nearly empty synthetic chain, not a Mainnet capacity measurement.

The publishing workflow independently builds and tests the release-profile
daemon. Mainnet sync, shielded-history qualification, and a 5 GB total-disk
qualification remain outstanding.
