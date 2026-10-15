import importlib.util
import os
import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("prepare", "/usr/local/lib/znode/prepare_config.py")
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def read_config(self):
        return tomllib.loads((self.root / "zakura.toml").read_text())

    def test_new_config_prunes_10000_and_keeps_rpc_private(self):
        prepare.prepare_config(self.root, 10000, "Mainnet")
        config = self.read_config()
        self.assertEqual(config["state"]["storage_mode"], {"pruned": {"tx_retention": 10000}})
        self.assertEqual(config["state"]["cache_dir"], "/zcash/zakura")
        self.assertEqual(config["rpc"]["listen_addr"], "127.0.0.1:8232")
        self.assertTrue(config["rpc"]["enable_cookie_auth"])
        self.assertEqual((self.root / "zakura.toml").stat().st_mode & 0o777, 0o600)

    def test_legacy_config_is_preserved_and_migrated_without_changing_network(self):
        old = '# keep this note\n[network]\nnetwork="Testnet"\n[state]\ncache_dir="/zcash"\nprune_keep_blocks=1000\n[mining]\nminer_address="existingAddress"\n'
        legacy = self.root / "zebrad.toml"
        legacy.write_text(old)
        prepare.prepare_config(self.root, 10000, "Mainnet")
        self.assertEqual(legacy.read_text(), old)
        self.assertIn("# keep this note", (self.root / "zakura.toml").read_text())
        config = self.read_config()
        self.assertEqual(config["network"]["network"], "Testnet")
        self.assertEqual(config["mining"]["miner_address"], "existingAddress")
        self.assertNotIn("prune_keep_blocks", config["state"])

    def test_archive_mode_is_replaced_and_original_is_backed_up(self):
        original = '# operator note\n[state]\nstorage_mode="archive"\n[rpc]\nenable_cookie_auth=false\n'
        (self.root / "zakura.toml").write_text(original)
        prepare.prepare_config(self.root, 10000, "Mainnet")
        self.assertEqual((self.root / "zakura.toml.before-znode-pruning").read_text(), original)
        first = (self.root / "zakura.toml").read_bytes()
        prepare.prepare_config(self.root, 10000, "Mainnet")
        self.assertEqual((self.root / "zakura.toml").read_bytes(), first)
        self.assertTrue(self.read_config()["rpc"]["enable_cookie_auth"])
        prepare.prepare_config(self.root, 14000, "Mainnet")
        self.assertEqual(self.read_config()["state"]["storage_mode"]["pruned"]["tx_retention"], 14000)
        self.assertEqual((self.root / "zakura.toml.before-znode-pruning").read_text(), original)

    def test_invalid_retention_does_not_write_config(self):
        with self.assertRaises(ValueError):
            prepare.prepare_config(self.root, 9999, "Mainnet")
        self.assertFalse((self.root / "zakura.toml").exists())

    def test_symlinks_are_rejected(self):
        (self.root / "zakura.toml").symlink_to(self.root / "missing")
        with self.assertRaises(ValueError):
            prepare.prepare_config(self.root, 10000, "Mainnet")

    def test_conflicting_environment_override_is_rejected(self):
        with patch.dict(os.environ, {"ZAKURA_STATE__STORAGE_MODE": "archive"}, clear=True):
            with patch("sys.argv", ["prepare_config.py", "--network", "Mainnet"]):
                with self.assertRaises(ValueError):
                    prepare.main()


if __name__ == "__main__":
    unittest.main()
