"""
Guards an unchecked empty ID list in BIOMERO's result import script.

`SLURM_Import_Results.py` reads the optional `ROI_Target_Image_IDs` parameter
and passes it straight to `getObjects("Image", ids=...)` without checking it.
Nothing supplies that parameter unless ROIs are requested, so an ordinary
segmentation run reaches the call with an empty list, OMERO renders it as
`where obj.id in ()`, and Hibernate rejects the query:

    ApiUsageException: unexpected end of subtree
      [select obj from ome.model.core.Image obj ... where obj.id in ()]

The workflow has already succeeded on Slurm by then, so the run reports FAILED
at 90% with its results sitting on disk under `.analyzed/<uuid>/<ts>/` and
nothing imported. The call runs unconditionally after extraction, ahead of the
task-based fallback that would otherwise supply real IDs.

New in biomero-scripts 2.8.2; `ROI_Target_Image_IDs` does not exist in v2.7.0.
See deployment_docs/upstream-suggestions.md item 9.

Applied to the server image only, because that is where the scripts live.
Running it twice is a no-op.

If this fails after a BIOMERO upgrade, check whether upstream now guards the
call and delete this file rather than re-anchoring the patch.
"""

from pathlib import Path
import os
import sys


SCRIPT_REL = "lib/scripts/biomero/_data/SLURM_Import_Results.py"

OLD = '''            input_images = [
                img for img in conn.getObjects(
                    "Image", ids=[int(i) for i in _roi_target_ids])
                if img
            ]'''

NEW = '''            input_images = [] if not _roi_target_ids else [
                img for img in conn.getObjects(
                    "Image", ids=[int(i) for i in _roi_target_ids])
                if img
            ]'''


def _script_path() -> Path:
    dist = os.environ.get("OMERO_DIST", "/opt/omero/server/OMERO.server")
    path = Path(dist) / SCRIPT_REL
    if not path.exists():
        raise FileNotFoundError(f"Could not locate {path}")
    return path


def patch_import_results() -> None:
    path = _script_path()
    source = path.read_text(encoding="utf-8")

    # Re-running the patch on an already-patched file is a no-op, so image
    # rebuilds stay safe.
    if "[] if not _roi_target_ids else [" in source:
        return

    count = source.count(OLD)
    if count != 1:
        raise RuntimeError(
            "Could not patch SLURM_Import_Results.py: expected 1 unguarded "
            f"getObjects(ids=_roi_target_ids) call, found {count}. Upstream may "
            "have guarded it; see deployment_docs/upstream-suggestions.md item 9 "
            "and delete this patch rather than re-anchoring it."
        )

    path.write_text(source.replace(OLD, NEW), encoding="utf-8")
    print(f"Patched {path}: guarded empty ROI_Target_Image_IDs", file=sys.stderr)


if __name__ == "__main__":
    patch_import_results()
