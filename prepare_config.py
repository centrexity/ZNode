"""Maintain ZNode's native pruning and safely migrate the old wrapper config."""

import argparse
import os
import tempfile
from collections.abc import MutableMapping
from pathlib import Path

import tomlkit


def section(document, name):
    value = document.setdefault(name, tomlkit.table())
    if not isinstance(value, MutableMapping):
        raise ValueError(f"[{name}] must be a TOML table")
    return value


def atomic_write(path, contents):
    descriptor, temporary = tempfile.mkstemp(prefix=".znode-config-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(contents)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def prepare_config(config_dir, retention, network, miner_address=""):
    if retention < 10000:
        raise ValueError("Mainnet/Testnet retention must be at least 10000 blocks")
    destination = config_dir / "zakura.toml"
    legacy = config_dir / "zebrad.toml"
    for path in (destination, legacy):
        if path.is_symlink():
            raise ValueError(f"configuration must not be a symlink: {path.name}")
    source = destination if destination.exists() else legacy if legacy.exists() else None
    previous = source.read_text(encoding="utf-8") if source else ""
    document = tomlkit.parse(previous)

    net = section(document, "network")
    net.setdefault("network", network)
    port = 8233 if str(net["network"]).lower() == "mainnet" else 18233
    net.setdefault("listen_addr", f"0.0.0.0:{port}")
    net.setdefault("p2p_stack", "legacy")
    net["cache_dir"] = "/zcash/zakura"

    state = section(document, "state")
    state.pop("prune_keep_blocks", None)
    state["cache_dir"] = "/zcash/zakura"
    state["storage_mode"] = {"pruned": {"tx_retention": retention}}

    rpc = section(document, "rpc")
    rpc["listen_addr"] = "127.0.0.1:8232"
    rpc["enable_cookie_auth"] = True
    rpc["cookie_dir"] = "/config/rpc"
    section(document, "tracing").setdefault("use_color", False)
    if source != destination and miner_address:
        section(document, "mining")["miner_address"] = miner_address

    rendered = tomlkit.dumps(document)
    if source == destination and previous == rendered:
        return
    backup = config_dir / "zakura.toml.before-znode-pruning"
    if source == destination and not backup.exists():
        with backup.open("x", encoding="utf-8") as output:
            output.write(previous)
        backup.chmod(0o600)
    atomic_write(destination, rendered)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--network", choices=["Mainnet", "Testnet"], required=True)
    args = parser.parse_args()
    controlled = (
        "ZAKURA_STATE__STORAGE_MODE", "ZEBRA_STATE__STORAGE_MODE",
        "ZAKURA_STATE__CACHE_DIR", "ZEBRA_STATE__CACHE_DIR",
        "ZAKURA_RPC__ENABLE_COOKIE_AUTH", "ZEBRA_RPC__ENABLE_COOKIE_AUTH",
        "ZAKURA_RPC__LISTEN_ADDR", "ZEBRA_RPC__LISTEN_ADDR",
        "ZAKURA_RPC__COOKIE_DIR", "ZEBRA_RPC__COOKIE_DIR",
    )
    if any(name == prefix or name.startswith(prefix + "__") for name in os.environ for prefix in controlled):
        raise ValueError("native overrides conflict with ZNode's managed pruning, cache or RPC settings")
    prepare_config(
        Path("/config"), int(os.environ["ZEC_PRUNE_KEEP_BLOCKS"]),
        args.network, os.environ.get("ZEC_MINER_ADDRESS", ""),
    )


if __name__ == "__main__":
    main()
