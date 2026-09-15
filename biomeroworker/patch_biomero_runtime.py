"""
Adds workflow output verification to BIOMERO's generated Slurm job scripts.

A workflow container can print a Python traceback, exit zero, and leave
`data/out` empty. Without a check, BIOMERO proceeds into import and hangs around
90%. This injects `_nl_biomero_verify_outputs` so the job fails immediately
instead.

Applied in both the worker and web images, because OMERO.biomero submits
analyzer jobs from the web process. Running it twice is a no-op.

Everything else this deployment needs is upstream BIOMERO configuration; see
setup_docs/deployment.md. Do not add patches here for behavior that a
slurm-config.ini or BIOMERO_* setting already provides.

If this fails after a BIOMERO upgrade, check whether upstream verifies outputs
itself and delete this file rather than re-anchoring the patch.
"""

from pathlib import Path
import site
import sys


PATCH_DIR = Path(__file__).resolve().parent / "patches"


def _replace_required(source: str, old: str, new: str, description: str) -> str:
    if old not in source:
        raise RuntimeError(f"Could not patch BIOMERO slurm_client.py: {description}")
    return source.replace(old, new)


def _biomero_file(name: str) -> Path:
    # Locate BIOMERO inside the active container venv without importing it.
    # Importing can fail while the package is half-patched during image build.
    candidates = []
    for base in site.getsitepackages() + [site.getusersitepackages(), *sys.path]:
        if base:
            candidates.append(Path(base) / "biomero" / name)
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise FileNotFoundError(f"Could not locate biomero/{name}")


def _read_patch(path: str) -> str:
    return (PATCH_DIR / path).read_text(encoding="utf-8")


def patch_slurm_client() -> None:
    path = _biomero_file("slurm_client.py")
    source = path.read_text(encoding="utf-8")
    generated_job_helper = _read_patch("generated_job_postprocess.py")

    # Re-running the patch on an already-patched file is a no-op, so image
    # rebuilds and the shared worker/web invocations stay safe.
    if "_nl_biomero_normalize_generated_job_script" in source:
        return

    source = _replace_required(
        source,
        "\nclass SlurmJob:",
        f"\n{generated_job_helper}\n\nclass SlurmJob:",
        "generated Slurm job helper insertion",
    )

    # When slurm_script_repo is empty, BIOMERO generates scripts locally and
    # uploads them directly. Append output verification to that supported
    # generated-script path. If an administrator supplies a custom Git
    # repository, BIOMERO uses it as provided and NL-BIOMERO does not mutate
    # that repository contract.
    source = _replace_required(
        source,
        """            job_script = src.safe_substitute(substitutes)
        return job_script
""",
        """            job_script = src.safe_substitute(substitutes)
        job_script = _nl_biomero_normalize_generated_job_script(job_script)
        return job_script
""",
        "generated Slurm job script output verification",
    )

    path.write_text(source, encoding="utf-8")


if __name__ == "__main__":
    patch_slurm_client()
