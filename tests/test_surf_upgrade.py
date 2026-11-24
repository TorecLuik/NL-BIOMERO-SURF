# Copyright (c) 2026, NL-BioImaging. BSD 2-Clause License; see LICENSE.
"""Exercise migration preservation and the resolved SURF Compose model."""

import configparser
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("upgrade", ROOT / "scripts/upgrade-config.py")
UPGRADE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPGRADE)


class ConfigurationUpgradeTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="surf-config-test-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        (self.root / "web").mkdir()
        self.volume = self.root / "volume"
        self.volume.mkdir()
        self.original_env = (
            f"OMERO_DATA_PATH={self.volume.as_posix()}\nSPIDER_USER=demo\nSPIDER_PROJECT=demo\n"
            "BIOMERO_VERSION=2.8.2\nPOSTGRES_PASSWORD=keep-this-test-value\n"
            "OMERO_ROOT_PASSWORD=keep-root-test-value\n"
            "BIOMERO_INJECT_GPU_FLAG=false\nBIOMERO_DETACHED_WORKFLOWS=FALSE\n"
            "SITE_ONLY_SETTING=preserve\n"
        )
        (self.root / ".env").write_text(self.original_env)
        self.original_slurm = (
            "[SSH]\nhost = spider\n[SLURM]\ngpu_partition = custom_gpu\n"
            "remote_shallow_zarr = false\nimage_pull_cpus = 8\n"
            "[WORKFLOWS]\ncisegmentation_repo = site/workflow\n"
            "cisegmentation_version = v0.6.4\n"
        )
        (self.root / "web/slurm-config.ini").write_text(self.original_slurm)
        self.site_config = {
            "group_mappings": {"53": {"folder": "leiden", "groupName": "Leiden"}},
            "PREPROCESSING_CONFIG": {
                "screen_db": {"container": "cellularimagingcf/biomero-converter:latest"},
                "dataset_leica_uuid": {"container": "site/custom-converter:v1"},
            },
            "custom_setting": 42,
        }
        (self.root / "web/biomero-config.json").write_text(json.dumps(self.site_config))
        # An unrelated upstream demo file must not override the live mappings.
        (self.root / "web/group-mappings.json").write_text('{"0": {"folder": "Project B"}}')

    def plan(self):
        with patch.object(UPGRADE.os.path, "ismount", return_value=True):
            return UPGRADE.prepare_upgrade(self.root)

    def apply(self, changes):
        for path, content in changes.items():
            UPGRADE.write_configuration(path, content, 0o600 if path.name == ".env" else 0o666)

    def test_dry_plan_preserves_secrets_settings_and_legacy_files(self):
        changes, keys = self.plan()
        env = UPGRADE.read_environment(changes[self.root / ".env"])
        self.assertEqual(env["BIOMERO_VERSION"], "2.9.0b33")
        self.assertEqual(env["POSTGRES_PASSWORD"], "keep-this-test-value")
        self.assertEqual(env["OMERO_ROOT_PASSWORD"], "keep-root-test-value")
        self.assertEqual(env["SITE_ONLY_SETTING"], "preserve")
        self.assertEqual(env["BIOMERO_DETACHED_WORKFLOWS"], "FALSE")
        self.assertNotIn("POSTGRES_PASSWORD", keys)
        self.assertEqual((self.root / ".env").read_text(), self.original_env)
        self.assertEqual((self.root / "web/slurm-config.ini").read_text(), self.original_slurm)
        self.assertFalse((self.volume / "config").exists())
        slurm = configparser.ConfigParser(interpolation=None)
        slurm.read_string(changes[self.volume / "config/slurm-config.ini"])
        self.assertEqual(slurm["SLURM"]["gpu_partition"], "custom_gpu")
        self.assertEqual(slurm["SLURM"]["image_pull_cpus"], "8")
        self.assertEqual(slurm["SLURM"]["inject_gpu_flag"], "false")
        self.assertEqual(slurm["SLURM"]["remote_shallow_zarr"], "false")
        self.assertEqual(slurm["WORKFLOWS"]["cisegmentation_version"], "v0.6.4")
        groups = json.loads(changes[self.volume / "config/group-mappings.json"])
        self.assertEqual(groups, self.site_config["group_mappings"])
        config = json.loads(changes[self.volume / "config/biomero-config.json"])
        self.assertEqual(config["custom_setting"], 42)
        self.assertEqual(config["PREPROCESSING_CONFIG"]["screen_db"]["container"],
                         "cellularimagingcf/biomero-converter:0.2.5")
        self.assertEqual(config["PREPROCESSING_CONFIG"]["dataset_leica_uuid"]["container"],
                         "site/custom-converter:v1")

    def test_second_upgrade_keeps_admin_edits_and_is_idempotent(self):
        self.apply(self.plan()[0])
        slurm_path = self.volume / "config/slurm-config.ini"
        slurm_path.write_text(slurm_path.read_text().replace("image_pull_cpus = 8", "image_pull_cpus = 3"))
        groups_path = self.volume / "config/group-mappings.json"
        groups_path.write_text('{"55": {"folder": "admin-new-path"}}')
        changes, keys = self.plan()
        self.assertEqual(changes, {})
        self.assertEqual(keys, [])
        self.assertIn("image_pull_cpus = 3", slurm_path.read_text())
        self.assertEqual(json.loads(groups_path.read_text())["55"]["folder"], "admin-new-path")

    def test_retired_environment_overrides_migrate_once_with_precedence(self):
        path = self.root / ".env"
        path.write_text(self.original_env + "BIOMERO_PULL_CPUS=2\nBIOMERO_PULL_MEM=9G\n"
                        "BIOMERO_APPTAINER_TMPDIR=/project/${SPIDER_PROJECT}/custom-tmp\n"
                        "BIOMERO_APPTAINER_CACHEDIR=/project/${SPIDER_PROJECT}/custom-cache\n"
                        "BIOMERO_IMAGE_PULL_VIA_SBATCH=false\nBIOMERO_ENV_FILE_SUBMISSION=false\n")
        self.apply(self.plan()[0])
        slurm_path = self.volume / "config/slurm-config.ini"
        config = configparser.ConfigParser(interpolation=None)
        config.read(slurm_path)
        for key, expected in {"image_pull_cpus": "2", "image_pull_mem": "9G",
                              "apptainer_tmpdir": "/project/demo/custom-tmp",
                              "apptainer_cachedir": "/project/demo/custom-cache",
                              "slurm_image_pull_via_sbatch": "false",
                              "env_file_submission": "false", "inject_gpu_flag": "false"}.items():
            self.assertEqual(config["SLURM"][key], expected)
        slurm_path.write_text(slurm_path.read_text().replace("image_pull_cpus = 2", "image_pull_cpus = 5"))
        self.assertEqual(self.plan(), ({}, []))
        self.assertIn("image_pull_cpus = 5", slurm_path.read_text())

    def test_missing_mount_refuses_before_any_write(self):
        with patch.object(UPGRADE.os.path, "ismount", return_value=False):
            with self.assertRaisesRegex(ValueError, "attached mount"):
                UPGRADE.prepare_upgrade(self.root)
        self.assertFalse((self.volume / "config").exists())
        self.assertEqual((self.root / ".env").read_text(), self.original_env)

    def test_missing_legacy_slurm_uses_parameterized_template(self):
        (self.root / "web/slurm-config.ini").unlink()
        changes, _ = self.plan()
        rendered = changes[self.volume / "config/slurm-config.ini"]
        self.assertIn("/project/demo/Share/biomero/data", rendered)
        self.assertNotIn("${SPIDER_PROJECT}", rendered)

    def test_invalid_json_refuses_plan(self):
        (self.root / "web/biomero-config.json").write_text("broken")
        with self.assertRaises(ValueError):
            self.plan()
        self.assertFalse((self.volume / "config").exists())

    def test_duplicate_environment_key_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            UPGRADE.update_environment("BIOMERO_VERSION=old\nBIOMERO_VERSION=new\n", {})

    @unittest.skipIf(os.name == "nt", "POSIX symlink/ownership check runs in Linux CI")
    def test_configuration_write_preserves_symlink_and_private_mode(self):
        target = self.volume / "private-env"
        target.write_text(self.original_env)
        target.chmod(0o640)
        link = self.root / ".env"
        link.unlink()
        link.symlink_to(target)
        UPGRADE.write_configuration(link, "SITE_ONLY_SETTING=updated\n", 0o600)
        self.assertTrue(link.is_symlink())
        self.assertEqual(target.read_text(), "SITE_ONLY_SETTING=updated\n")
        self.assertEqual(target.stat().st_mode & 0o777, 0o640)


class ComposeIntegrationTests(unittest.TestCase):
    def compose_model(self, flags=None):
        # Compose config needs no daemon and never starts a service.
        values = UPGRADE.read_environment((ROOT / ".env.example").read_text())
        values.update(OMERO_DATA_PATH="/data/surf-biomero-storage", SPIDER_USER="demo", SPIDER_PROJECT="demo")
        values = {key: value.replace("CHANGE ME", "test-only").replace("CHANGE-ME", "test-only")
                  for key, value in values.items()}
        for key, value in (flags or {}).items():
            if value is None:
                values.pop(key, None)
            else:
                values[key] = value
        env = {key: value for key, value in os.environ.items()
               if key not in values and not key.startswith("COMPOSE_")}
        with tempfile.TemporaryDirectory(prefix="surf-compose-test-") as scratch:
            path = Path(scratch) / "test.env"
            path.write_text("\n".join(f"{key}={value}" for key, value in values.items()) + "\n")
            result = subprocess.run(
                ["docker", "compose", "--env-file", str(path), "config", "--format", "json"],
                cwd=ROOT, env=env, capture_output=True, text=True, timeout=45, check=True,
            )
        return json.loads(result.stdout)["services"]

    def test_site_storage_ports_configuration_and_metabase_survive_merge(self):
        services = self.compose_model()
        for name in ("database", "database-biomero"):
            mount = next(v for v in services[name]["volumes"] if v["target"] == "/var/lib/postgresql/data")
            self.assertEqual(mount["type"], "bind")
            self.assertTrue(mount["source"].replace("\\", "/").endswith(f"/surf-biomero-storage/{name}"))
        for name in ("omeroserver", "omeroworker-1", "biomeroworker", "omeroweb", "biomero-importer", "zarrviewer-nginx"):
            mounts = services[name]["volumes"]
            self.assertEqual(len({v["target"] for v in mounts}), len(mounts))
            data = next(v for v in mounts if v["target"] == "/data")
            self.assertTrue(data["source"].replace("\\", "/").endswith("/surf-biomero-storage/L-Drive"))
        for name in ("biomeroworker", "omeroweb", "biomero-importer"):
            config = [v for v in services[name]["volumes"] if v["target"].endswith("group-mappings.json")]
            self.assertEqual(len(config), 1)
            self.assertTrue(config[0]["source"].replace("\\", "/").endswith("/config/group-mappings.json"))
        self.assertNotIn("ports", services["omeroweb"])
        self.assertEqual(services["biomero-importer"]["entrypoint"], [
            "/opt/conda/envs/auto-import-env/bin/python", "-m", "biomero_importer.main",
        ])
        for name in ("zarrviewer-nginx", "metabase"):
            self.assertEqual(len(services[name]["ports"]), 1)
            self.assertEqual(services[name]["ports"][0]["host_ip"], "127.0.0.1")
        mb = services["metabase"]
        self.assertEqual(mb["environment"]["MB_DB_TYPE"], "postgres")
        self.assertNotIn("MB_DB_FILE", mb["environment"])
        self.assertFalse(mb.get("volumes"))
        self.assertEqual(mb["environment"]["MB_EMBEDDING_SECRET_KEY"],
                         services["omeroweb"]["environment"]["METABASE_SECRET_KEY"])

    def test_new_features_enabled_and_can_be_explicitly_disabled(self):
        for value in ("TRUE", "FALSE", "", None):
            with self.subTest(value=value):
                flags = {k: value for k in ("BIOMERO_DETACHED_WORKFLOWS", "BIOMERO_SHALLOW_ZARR", "BIOMERO_ZARR_VIEWER_ENABLED")}
                services = self.compose_model(flags)
                for name in ("biomeroworker", "omeroweb"):
                    self.assertEqual(services[name]["environment"]["BIOMERO_DETACHED_WORKFLOWS"], value or "false")
                    self.assertEqual(services[name]["environment"]["BIOMERO_SHALLOW_ZARR"], value or "false")
                self.assertEqual(services["omeroweb"]["environment"]["BIOMERO_ZARR_VIEWER_ENABLED"], value or "false")


if __name__ == "__main__":
    unittest.main()
