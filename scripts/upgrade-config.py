#!/usr/bin/env python3
# Copyright (c) 2026, NL-BioImaging. BSD 2-Clause License; see LICENSE.
"""Update SURF release pins and preserve administrator configuration on its volume."""

import argparse
import configparser
import json
import os
from pathlib import Path
import re
import stat
from string import Template
import tempfile

SOURCE_ROOT = Path(__file__).resolve().parent.parent
ENV_ASSIGNMENT = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$")
RUNTIME_FILES = {
    "SLURM_CONFIG_HOST_PATH": "slurm-config.ini",
    "BIOMERO_CONFIG_HOST_PATH": "biomero-config.json",
    "GROUP_MAPPINGS_HOST_PATH": "group-mappings.json",
}
LEGACY_PREPROCESSING = {
    "screen_db": {"container": "cellularimagingcf/biomero-converter:latest"},
    "dataset_leica_uuid": {
        "container": "cellularimagingcf/convertleica-docker:v1.5.0",
        "extra_params": {"image_uuid": "{UUID}"},
    },
    "incucyte_archive": {"container": "cellularimagingcf/biomero-converter:latest"},
}


def read_environment(text: str) -> dict[str, str]:
    """Read assignments without evaluating shell code or printing their values."""
    values = {}
    for line in text.splitlines():
        match = ENV_ASSIGNMENT.match(line)
        if match:
            key, value = match.groups()
            if key in values:
                raise ValueError(f"Duplicate environment key: {key}")
            values[key] = value
    return values


def unquote(value: str) -> str:
    """Remove matching outer quotes from an environment value."""
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def resolve_path(value: str, values: dict[str, str], root: Path) -> Path:
    """Resolve deployment path variables without sourcing the environment."""
    value = unquote(value)
    for _ in range(10):
        expanded = Template(value).substitute({k: unquote(v) for k, v in values.items()})
        if expanded == value:
            path = Path(value)
            return path if path.is_absolute() else root / path
        value = expanded
    raise ValueError("Recursive deployment path variables")


def update_environment(original: str, defaults: dict[str, str]) -> tuple[str, list[str]]:
    """Update release pins and add missing keys, retaining all other site values."""
    values = read_environment(original)
    replacements = {k: v for k, v in defaults.items()
                    if k.endswith("_VERSION") or k not in values}
    changed = sorted(k for k, v in replacements.items() if values.get(k) != v)
    lines = []
    for line in original.splitlines():
        match = ENV_ASSIGNMENT.match(line)
        key = match.group(1) if match else None
        lines.append(f"{key}={replacements[key]}" if key in replacements else line)
    lines.extend(f"{key}={defaults[key]}" for key in defaults if key not in values)
    return "\n".join(lines) + "\n", changed


def add_slurm_defaults(text: str, values: dict[str, str]) -> str:
    """Add new runtime controls without changing existing settings or workflows."""
    parser = configparser.ConfigParser(interpolation=None)
    parser.read_string(text)
    if not parser.has_section("SLURM"):
        raise ValueError("Slurm configuration has no [SLURM] section")
    additions = {
        "inject_gpu_flag": unquote(values.get("BIOMERO_INJECT_GPU_FLAG", "true")),
        "env_file_submission": unquote(values.get("BIOMERO_ENV_FILE_SUBMISSION", "true")),
        "ssh_recovery_timeout": "900",
        "remote_shallow_zarr": "true",
        "remote_shallower_workers": "1",
        "remote_shallower_partition": "",
        "remote_shallower_mem": "",
        "remote_shallower_time": "",
    }
    missing = [f"{key} = {value}" for key, value in additions.items()
               if not parser.has_option("SLURM", key)]
    if not missing:
        return text
    return text.replace("[SLURM]", "[SLURM]\n" + "\n".join(missing), 1)


def upgrade_preprocessing(content: str, defaults: str) -> str:
    """Advance only unchanged legacy converter recipes to the release defaults."""
    config = json.loads(content)
    recipes = config.get("PREPROCESSING_CONFIG", {})
    current_defaults = json.loads(defaults)["PREPROCESSING_CONFIG"]
    changed = False
    for name, legacy in LEGACY_PREPROCESSING.items():
        if recipes.get(name) == legacy:
            recipes[name] = current_defaults[name]
            changed = True
    return json.dumps(config, indent=2) + "\n" if changed else content


def write_configuration(path: Path, content: str, mode: int = 0o666) -> None:
    """Atomically write configuration, preserving an existing file's ownership."""
    path = path.resolve()  # Preserve older deployments' symlinks into config/.
    previous = path.stat() if path.exists() else None
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
            output.write(content)
        temporary.chmod(stat.S_IMODE(previous.st_mode) if previous else mode)
        if previous and hasattr(os, "chown"):
            os.chown(temporary, previous.st_uid, previous.st_gid)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def prepare_upgrade(root: Path, source: Path = SOURCE_ROOT) -> tuple[dict[Path, str], list[str]]:
    """Plan configuration changes using live files before committed examples."""
    env_path = root / ".env"
    original = env_path.read_text(encoding="utf-8")
    defaults = read_environment((source / ".env.example").read_text(encoding="utf-8"))
    updated, keys = update_environment(original, defaults)
    values = read_environment(updated)
    volume = resolve_path(values["OMERO_DATA_PATH"], values, root)
    if not os.path.ismount(volume):
        raise ValueError("OMERO_DATA_PATH must be an attached mount before migrating configuration")

    changes = {}
    for key, name in RUNTIME_FILES.items():
        target = resolve_path(values[key], values, root)
        legacy = root / "web" / name
        if target.exists():
            content = target.read_text(encoding="utf-8")
        elif name == "group-mappings.json":
            # The old SURF plugin used mappings embedded in biomero-config.json.
            # Do not adopt upstream's unrelated demo group IDs from web/.
            config_path = resolve_path(values["BIOMERO_CONFIG_HOST_PATH"], values, root)
            config_text = changes.get(config_path)
            if config_text is None:
                config_text = config_path.read_text(encoding="utf-8")
            content = json.dumps(json.loads(config_text).get("group_mappings", {}), indent=2) + "\n"
        elif legacy.is_file():
            content = legacy.read_text(encoding="utf-8")
        elif name == "slurm-config.ini":
            content = (source / "web/slurm-config-template.ini").read_text(encoding="utf-8")
            for variable in ("SPIDER_USER", "SPIDER_PROJECT"):
                content = content.replace("${" + variable + "}", unquote(values[variable]))
        else:
            content = (source / "web" / name).read_text(encoding="utf-8")
        if name == "slurm-config.ini":
            content = add_slurm_defaults(content, values)
        elif name == "biomero-config.json":
            content = upgrade_preprocessing(
                content, (source / "web/biomero-config.json").read_text(encoding="utf-8")
            )
        else:
            json.loads(content)  # Validate before writing anything.
        if not target.exists() or target.read_text(encoding="utf-8") != content:
            changes[target] = content
    if updated != original:
        changes[env_path] = updated  # Publish paths only after their files exist.
    return changes, keys


def main() -> int:
    """Apply or check the migration without deploying services or changing secrets."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=SOURCE_ROOT)
    parser.add_argument("--check", action="store_true", help="Report pending changes without writing")
    args = parser.parse_args()
    try:
        root = args.root.resolve()
        changes, keys = prepare_upgrade(root)
        print(f"Release environment keys to update: {', '.join(keys) or 'none'}")
        for path, content in changes.items():
            print(f"{'Would update' if args.check else 'Updating'} {path}")
            if not args.check:
                write_configuration(path, content, 0o600 if path.name == ".env" else 0o666)
        print("Configuration current" if not changes else "Configuration changes planned" if args.check else "Configuration updated; deploy separately")
        return 1 if args.check and changes else 0
    except (OSError, ValueError, KeyError, configparser.Error) as exc:
        # Parser exceptions can contain configuration values. Report only type.
        print(f"Configuration upgrade failed ({type(exc).__name__}); check mount, paths and configuration syntax")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
