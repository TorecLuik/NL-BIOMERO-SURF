# Upstream Suggestions

*Created 2026-09-17*

Findings from this deployment that belong upstream rather than in local
configuration. Each one is reproducible here and cost real debugging time.

Versions in use: `biomero 2.8.2`, `omero-biomero 1.6.1`,
`BIOMERO.importer 1.4.2`, `SLURM_Import_Results.py 2.7.0`.

## 1. A table-only workflow fails unless an image option is cleared

**Repo:** BIOMERO (`SLURM_Import_Results.py`)

`Nuclei Measurements` produces CSVs and no images. Run it with
*Add (mask) image results to a dataset* set, and the script takes the importer
path, scans for image extensions, finds none, and exits:

```text
CRITICAL: No image files found for importer processing - workflow failed!
```

`sys.exit(1)` is at line 2920; `process_slurm_tables` is at 4043. Requested
outputs after the importer step never run, so the measurement tables are never
attached even with *Measurement Tables* on. The workflow still reports `DONE` at
100%, because the Slurm job itself succeeded, and only the Slurm log is
attached. The results are on disk under `/data/root/.analyzed/<uuid>/<ts>/`.

Three separate things make this hard to diagnose:

- The UI marks *Add (mask) image results to a dataset* **Suggested** for a
  workflow whose descriptor declares no image outputs.
- That option has no toggle. It is on whenever a dataset is selected, so the
  only way to turn it off is to clear the dataset chip -- not discoverable, and
  the other options in the same panel do have switches.
- "No images found" is treated as fatal rather than as "this workflow produced
  none", aborting outputs that were independently requested.

**Suggested:** do not exit when other output options are still pending; base the
*Suggested* badge on the descriptor's declared outputs; give the option a toggle
like its neighbours.

## 2. A failed ZARR export surfaces as an unrelated ValidationException

**Repo:** BIOMERO

When the OME-Zarr export fails, `_SLURM_Image_Transfer.py` still reports
`CREATED`. Nothing lands on Spider, and the failure appears two steps later as:

```text
SLURM_Remote_Conversion.py: Invalid parameters:
VALUE LIST for "Input data": biomero_<uuid> not in [...]
```

The message names a missing folder, which reads as a configuration fault. The
real cause is in `biomero.log`, e.g. `Critical error: ZARR export failed with
return code 1` behind an `ApiUsageException: Invalid C index: 1/1`.

**Suggested:** fail the transfer task when the export fails, and surface the
export error rather than the downstream symptom.

## 3. The importer always links, never copies

**Repo:** BIOMERO.importer

`--transfer=ln_s` is hardcoded in `biomero_importer/utils/importer.py`: keyword
defaults on `import_to_omero` and `import_dataset`, plus string literals at both
call sites. No setting, environment variable or upload-order field changes it.

The managed repository therefore holds symlinks into `/data`. Delete or move a
source file and its OMERO image becomes permanently unreadable, and a backup
that does not dereference archives the dangling link rather than the pixels.
Workflow results link into `/data/root/.analyzed/`, which is scratch space.

**Suggested:** make the transfer mode configurable, defaulting to copy for data
whose source is outside the deployment's control.

## 4. A ZARR-registered image exports an empty channel

**Repo:** BIOMERO, or omero-zarr-pixel-buffer

Submitting an image registered by external reference
(`com.glencoesoftware.ngff:multiscales`) runs the whole chain and produces
nothing. The export writes a 525 KB TIFF, cellpose reports
`No cell pixels found` with `divide by zero encountered in true_divide`, and the
1280-byte result is rejected:

```text
Zip file is too small (336 bytes), indicating no meaningful data was transferred
```

The Zarr renders correctly in the viewer, so the pixels are readable in place;
the channel exported for workflows has no dynamic range. The rejection message
blames the image export, which had in fact succeeded.

**Suggested:** worth confirming whether a Zarr-registered image is expected to
be usable as workflow input at all. If not, reject it at submission.

## 5. Importing a `.zarr` needs the whole pyramid, silently

**Repo:** omero-zarr-pixel-buffer, or its documentation

A Zarr whose `.zattrs` lists more resolution levels than exist on disk registers
without error and then fails on every read:

```text
java.io.IOException: '.zarray' expected but is not readable or missing in store
```

In OMERO.web this shows as a missing thumbnail; in iviewer as a `getTileSize`
`InternalException`. Nothing at import time reports the incomplete pyramid.

**Suggested:** validate the levels the `multiscales` metadata declares at
registration, and fail there with a message naming the missing level.

## 6. The Analyzer offers workflows the deployment has not configured

**Repo:** OMERO.biomero

`slurm-config.ini` registers 7 workflows here. The Analyzer lists 12, the extra
five coming from the descriptor catalog rather than from what this deployment
can run:

```text
registered   cellpose, stardist, stardist5d, cellexpansion, spotcounting,
             nuclei_measurements, aggregates_measurements
also listed  CellExpansionAdvanced, Fractal-Cellpose-SAM-Segmentation,
             SimpleZarrPlateProcessor, W_CIDeconvolve, BilayersTest
```

Nothing marks the difference, so picking one of the five fails at submission,
before any Slurm job exists.

**Suggested:** list only what `slurm-config.ini` registers, or mark the rest as
unavailable.

## Reporting

Repositories:

```text
BIOMERO             https://github.com/NL-BioImaging/biomero
BIOMERO.importer    https://github.com/NL-BioImaging/BIOMERO.importer
OMERO.biomero       https://github.com/NL-BioImaging/OMERO.biomero
```

Items 1 and 3 are the ones that cost the most time here, and both have a
one-line workaround worth including in any report: clear the dataset chip, and
use OMERO.insight for anything that must outlive its source file.
