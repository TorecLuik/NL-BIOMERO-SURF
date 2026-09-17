"""
Guards unchecked empty ID lists in BIOMERO's result scripts.

`SLURM_Import_Results.py` and `SLURM_Get_Results.py` read the optional
`ROI_Target_Image_IDs` parameter and pass it straight to
`getObjects("Image", ids=...)` without checking it:

    _roi_target_ids = unwrap(client.getInput(ROI_TARGET_IMAGE_IDS)) or []
    input_images = [img for img in conn.getObjects(
        "Image", ids=[int(i) for i in _roi_target_ids]) if img]

`SLURM_Run_Workflow.py` only forwards that parameter inside
`if selected_output.get(OUTPUT_CREATE_ROIS)`. Its else branch sets
`OUTPUT_CREATE_ROIS` to false and forwards nothing, so a workflow run without
ROIs reaches the call with an empty list. OMERO renders that as
`where obj.id in ()` and Hibernate rejects the query:

    ApiUsageException: unexpected end of subtree
      [select obj from ome.model.core.Image obj ... where obj.id in ()]

The workflow has already succeeded on Slurm by then, so the run reports FAILED
at 90% with its results on disk under `.analyzed/<uuid>/<ts>/` and nothing
imported. The call runs unconditionally after extraction, ahead of the
task-based fallback that would otherwise supply real IDs.

This is not a version-pairing problem: the producing and consuming code are both
in biomero-scripts, at the same tag. New in 2.8.2; `ROI_Target_Image_IDs` does
not exist in v2.7.0. See deployment_docs/upstream-suggestions.md item 9.

Applied to the server image only, because that is where the scripts live.
Running it twice is a no-op.

If this fails after a BIOMERO upgrade, check whether upstream now guards the
calls and delete this file rather than re-anchoring the patch.
"""

from pathlib import Path
import os
import re
import sys


SCRIPT_DIR_REL = "lib/scripts/biomero/_data"
TARGETS = ("SLURM_Import_Results.py", "SLURM_Get_Results.py")

# The two call sites are identical apart from indentation, so anchor on the
# structure and let the leading whitespace come from the file.
PATTERN = re.compile(
    r"(?P<indent>[ ]+)input_images = \[\n"
    r"(?P=indent)    img for img in conn\.getObjects\(\n"
    r"(?P=indent)        \"Image\", ids=\[int\(i\) for i in _roi_target_ids\]\)\n"
    r"(?P=indent)    if img\n"
    r"(?P=indent)\]"
)

GUARDED = (
    "{indent}input_images = [] if not _roi_target_ids else [\n"
    "{indent}    img for img in conn.getObjects(\n"
    "{indent}        \"Image\", ids=[int(i) for i in _roi_target_ids])\n"
    "{indent}    if img\n"
    "{indent}]"
)

ALREADY = "[] if not _roi_target_ids else ["


def _script_dir() -> Path:
    dist = os.environ.get("OMERO_DIST", "/opt/omero/server/OMERO.server")
    path = Path(dist) / SCRIPT_DIR_REL
    if not path.is_dir():
        raise FileNotFoundError(f"Could not locate {path}")
    return path


def patch_result_scripts() -> None:
    directory = _script_dir()
    for name in TARGETS:
        path = directory / name
        if not path.exists():
            raise FileNotFoundError(f"Could not locate {path}")

        source = path.read_text(encoding="utf-8")

        # Re-running the patch on an already-patched file is a no-op, so image
        # rebuilds stay safe.
        if ALREADY in source:
            continue

        matches = list(PATTERN.finditer(source))
        if len(matches) != 1:
            raise RuntimeError(
                f"Could not patch {name}: expected 1 unguarded "
                f"getObjects(ids=_roi_target_ids) call, found {len(matches)}. "
                "Upstream may have guarded it; see "
                "deployment_docs/upstream-suggestions.md item 9 and delete this "
                "patch rather than re-anchoring it."
            )

        indent = matches[0].group("indent")
        source = PATTERN.sub(lambda _m: GUARDED.format(indent=indent), source)
        path.write_text(source, encoding="utf-8")
        print(f"Patched {name}: guarded empty ROI_Target_Image_IDs",
              file=sys.stderr)


if __name__ == "__main__":
    patch_result_scripts()
