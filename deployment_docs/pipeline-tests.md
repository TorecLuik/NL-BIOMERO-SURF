# End-to-End Pipeline Tests

*Created 2026-09-17 · last updated 2026-09-17*

Manual tests that exercise the full chain — import, export to Spider, remote
conversion, Slurm workflow, results back in OMERO — using the datasets in
[reference-data.md](reference-data.md). They cover what the automated smoke
tests cannot reach: a workflow run with results imported back into OMERO, and
the importer picking up files unattended.

Everything here is done in the browser. Terminal commands appear only for
diagnosing a failure, never to run a test.

## Before starting

Open `https://<host>/` and log in. The
top bar carries a **BIOMERO** tab alongside Data, Figure and Forms; it lands on
`/omero_biomero/biomero/`, which is a single page holding the Importer, Analyzer
and Admin panels.

Confirm Spider is reachable: **BIOMERO → Analyze → Admin** shows cluster status.
If it is red, no workflow test can pass and the problem is not in these steps.

Give it a minute before believing it. The check queries Spider over SSH for
every workflow's available versions, and until it returns, each workflow card
reads **Offline** -- the same word it would show if the cluster really were
unreachable. Settled, the panel says "SLURM cluster is available", with the
number of workflows ready. The underlying call is `/omero_biomero/api/analyzer/slurm/status/`,
which is worth hitting directly when in doubt.

Import both reference images through the Importer:

```text
BIOMERO -> Importer -> browse to /data/reference-data
select both .ome.tiff files -> Import
```

**Pick the destination dataset first.** Until one is selected the panel reads
"Select OMERO dataset, project or screen to get started!" and *Add to import
list* stays disabled however many files are ticked -- the file selection is not
what enables it. Create the dataset in **Data** beforehand if none exists.

The Importer always imports by reference: the files under `ManagedRepository`
are symlinks back to `/data/reference-data` (see
[reference-data.md](reference-data.md)). That is fine for tests while the
reference data stays put, and is why P1 below is worth running -- deleting the
source would leave every image unreadable.

Below, `$FIG7` is `fig7_RSAdetection_16w` (2 channels, DNA on **C0**) and `$RGB`
is `6E3rd4hrSTFBGlc-1_Render_SeriesRGB` (3 channels, DNA on **C2**).

## How to run a workflow

Every test below uses the same dialog, so it is described once here.

Select the image in **Data**, then either use **BIOMERO → Analyzer**, or the
script menu (the gear icon) → `biomero` → `SLURM_Run_Workflow`. The dialog is
grouped; the fields that matter for these tests:

```text
Data_Type / IDs            prefilled from your selection
Use_ZARR_Format            leave OFF -- workflows here expect TIFF
Choose_Z_Section           "Max projection" flattens a Z-stack (see the trap below)
<workflow name>            tick the workflow, which reveals its parameters
2) Attach to original images
3a) Import into NEW Dataset   name it, e.g. "A1 nuclei"
3c) Rename the imported images   THE FIELD THAT DECIDES LATER TESTS
```

**`3c) Rename the imported images` is the one to get right.** Downstream
workflows find their inputs by filename suffix, and this field is where those
suffixes come from. It accepts `{original_file}`, `{original_ext}`, `{file}` and
`{ext}`. The required values are given per test.

## Checking a result

In the UI: **BIOMERO → Analyzer** lists runs with status and progress, and the
new images or tables appear in the target dataset under **Data**.

Only if something fails, from a terminal in the checkout (compose addresses
services by name, whatever the checkout directory is called):

```bash
# recent tasks, with the error text
sudo docker compose exec database-biomero psql -U biomero -d biomero -x \
  -c "SELECT task_name, status, error_type, start_time, end_time
      FROM biomero_task_execution ORDER BY start_time DESC LIMIT 10;"

# one run by its UUID. biomero_task_execution has no workflow_id column,
# so look the run up in the progress view.
sudo docker compose exec database-biomero psql -U biomero -d biomero -x \
  -c "SELECT * FROM biomero_workflow_progress_view WHERE workflow_id='<uuid>';"
```

## Order

The tests come in two chains plus three independent checks. Each chain runs top
to bottom; the second exists because quantification needs a 3-channel image.

```text
P1              prerequisite: the imports are usable
A1 -> A2        segment and expand $FIG7
B1 -> B2 -> B3  segment, expand and quantify $RGB
I1, I2, I3      independent, any time after P1
```

A2 and B2 are the same test on different input, so its settings are given once,
under A2.

## P1 — Imports are usable

A by-reference image is only as durable as its source file. In **Data**, open
each imported image. If it renders, its pixels are in the OMERO volume.

A by-reference import whose source has been deleted throws
`ResourceError: Error instantiating pixel buffer` instead of displaying, and
every workflow on it will fail later. To audit the whole repository at once:

```bash
sudo docker compose exec omeroserver bash -lc \
  'find /OMERO/ManagedRepository -type l ! -exec test -e {} \; -print'
```

**Pass:** images render; the command prints nothing.

A Zarr image legitimately has no fileset and no pixels path -- it is registered
by external reference and read in place -- so judge it by whether it previews,
not by those columns. A Zarr that shows `No preview` has an unreadable pyramid;
check the server log for `'.zarray' expected but is not readable`.

```bash
# plate wells legitimately have no fileset, so exclude well samples
sudo docker compose exec database psql -U omero -d omero \
  -c "SELECT i.id, i.name FROM image i JOIN pixels p ON p.image=i.id
      WHERE i.fileset IS NULL AND p.path IS NULL
        AND NOT EXISTS (SELECT 1 FROM wellsample ws WHERE ws.image=i.id);"
```

**Pass:** no rows. Delete any that appear before going further -- and never use
*Select ALL* in the picker while one exists, because a single bad image aborts
the whole batch and every other image in that run is lost.

## Chain A — $FIG7

Two channels, 512x512. Proves the chain works at all.

### A1 — Segmentation, the whole chain

The core test. Nuclei on the DNA channel of `$FIG7`.

```text
image       $FIG7
workflow    cellpose
  nuc_channel      1     C0 = DNA; the numbering is 1-based
  diameter         0     auto
  prob_threshold   0.5
  cp_model         nuclei
  use_gpu          true
3a) NEW Dataset  A1 nuclei
3c) Rename       {original_file}_Nuclei_Mask.{ext}
```

`nuc_channel` is 1-based over the image's channels, so C0 is `1`. The descriptor
words it as "0 for grayscale and RGB converted to grayscale by luminance; 1, 2
or 3 to select a specific RGB channel", which reads as RGB-only, but `1` does
select C0 on this 2-channel image.

The rename matters even though nothing in A1 reads it: B3 will not find a mask
under any other name.

Four stages run; the Analyzer shows progress through them:

```text
_SLURM_Image_Transfer.py     export to OME-Zarr, copy to Spider
SLURM_Remote_Conversion.py   CONVERT_ZARR_TO_TIFF
cellpose                     Slurm job on gpu_a100_22c
SLURM_Import_Results.py      mask imported back
```

**Pass:** status `DONE` at 100%, and a label image in `A1 nuclei` whose nuclei
visually match the DNA channel when flipped between the two in **Data**.

**Fail, and where to look:**

```text
ValidationException: "Input data": biomero_<uuid> not in [...]
  -> the zarr export failed and the error was swallowed, so no folder was ever
     created on Spider and conversion had nothing to pick from. The message
     names the missing folder, not the real fault. Real cause:
     sudo docker compose exec biomeroworker \
       grep -i "Critical error\|ResourceError" \
       /opt/omero/server/OMERO.server/var/log/biomero.log | tail
     Usually a broken by-reference import -- run P1.

Slurm job FAILED
  -> sudo docker compose exec biomeroworker \
       ssh spider "sacct -j <id> --format=JobID,State,ExitCode,Partition,ReqTRES%45 -P"
     then read ~/omero-<id>.log on Spider for the traceback.

ValueError: operands could not be broadcast together ... (2,2) and (4,2)
  -> a 3D or multi-channel stack reached a 2D-only workflow. See the trap below.

Invalid C index: 1/1  (in the biomero.log traceback)
  -> OMERO's channel count disagrees with what Bio-Formats reads from the file.
     For a hand-built OME-TIFF this usually means the OME metadata is missing;
     see the conversion note in reference-data.md.
```

### A2 — Cell expansion

Needs the nucleus mask from A1. Select the mask image, not the original.

```text
image       the nucleus mask
workflow    cellexpansion
  max_pixels                       25
  discard_cells_without_cytoplasm  true
3a) NEW Dataset  A2 cells
3c) Rename       leave EMPTY -- see below
```

**Leave the rename empty.** CellExpansion names its own output by taking the
input filename and replacing the literal substring `Nuclei` with `Cells`. Given
`..._Nuclei_Mask.tif` from A1 it produces `..._Cells_Mask.tif`, which is what B3
needs. If the input has no `Nuclei` in its name, input and output names
collide and the run is unusable — which is why A1 sets the rename.

CellExpansion reads only the mask and never the original, so it has no channel
parameters and these settings are the same whichever image the mask came from.

**Pass:** a cell mask in `A2 cells`, each cell containing one nucleus and
extending beyond it.

## Chain B — $RGB

Three channels, 1114x1757. Repeats the segmentation on a different image shape,
and is the only chain that can reach quantification: the CellProfiler pipeline
loads the original as a colour image and needs three channels.

### B1 — Segmentation on the RGB image

The same segmentation on `$RGB`. A1 must have passed first; this repeats it on a
different image shape and starts the chain B3 needs.

```text
image       $RGB
workflow    cellpose
  nuc_channel      3     C2 = DNA (blue)
  diameter         0     auto
  prob_threshold   0.5
  cp_model         nuclei
  use_gpu          true
3a) NEW Dataset  B1 nuclei
3c) Rename       {original_file}_Nuclei_Mask.{ext}
```

`nuc_channel` is `3` for C2, unambiguous here because the image really is
3-channel RGB. Everything else matches A1.

Worth running separately: `$RGB` is 3-channel where `$FIG7` is 2-channel, and
1114x1757 where `$FIG7` is 512x512. It crosses the 1024 px tile size in both
dimensions, so it is the only reference image that exercises tiling, and the
wrapper pads non-square images up to at least 224 and crops back afterwards.

**Pass:** as A1, and the returned mask is the full 1114x1757.

### B2 — Cell expansion on the RGB mask

A2 again, against B1's mask. Same settings -- CellExpansion reads only the mask,
never the original, so nothing changes with the channel count. Leave `3c) Rename`
empty so it produces `..._Cells_Mask...` itself.

**Pass:** a cell mask in its dataset, each cell containing one nucleus and
extending beyond it.

### B3 — Quantification

Needs the original plus both masks, all built from `$RGB`. The A-chain masks are
built on `$FIG7` and cannot be used here, for the channel reason below.

```text
images      $RGB + the B1 mask + the B2 mask   (select all three)
workflow    nuclei_measurements
  nuclei_mask_suffix   _Nuclei_Mask
  cells_mask_suffix    _Cells_Mask
  metric_channels      1,2,3      the default; $RGB has three channels
Add (mask) image results to a dataset   NO dataset -- clear the chip
Measurement Tables                      ON
```

**Use `$RGB`, not `$FIG7`.** The CellProfiler pipeline loads the original
through `NamesAndTypes` as a *colour* image, so it needs three channels. Run on
the 2-channel `$FIG7` it fails inside CellProfiler with:

```text
ValueError: cannot reshape array of size 524288 into shape (512,512)
```

524288 is 512x512x2: the reader got two channels where the pipeline expected a
colour image. Setting `metric_channels` to `1,2` does not help -- the wrapper
reconfigures the measurement channels but not how the image is loaded. The
descriptor's own wording gives it away: "E.g. 1,2,3 for RGB".

This is why the B chain exists: B1 and B2 build the masks on `$RGB`.

Two traps, both silent:

- The suffixes above are the workflow's defaults, and they are what B1 and B2
  were named to produce. Any other spelling and the pipeline matches nothing.
  The match is on a substring, so the accumulated `.0.tif` extensions that a
  round trip adds do not break it.
- `metric_channels` defaults to `1,2,3`, which is correct for `$RGB`. The
  wrapper only reconfigures channels when the value differs from the default.

**Clear the dataset from `Add (mask) image results to a dataset`.** That option
has no toggle: it is on whenever a dataset is selected, so removing the chip is
how to turn it off. Leave `Measurement Tables` on.

This matters because the workflow produces only CSVs. With a dataset selected,
`SLURM_Import_Results.py` takes the importer path, scans for *image* files,
finds none and calls `sys.exit(1)` -- about a thousand lines before it would
have processed the tables:

```text
CRITICAL: No image files found for importer processing - workflow failed!
```

The workflow still reports `DONE` at 100%, because the Slurm job itself
succeeded, and only the Slurm log gets attached. The UI marks the option
"Suggested" even though this workflow declares no image outputs, so following
the suggestion is what breaks it.

**Pass:** five `OMERO.tables` attached to the dataset -- `Nuclei`, `Cells`,
`Cytoplasm`, `Experiment` and `metadata` -- one row per object. The CSVs are
also written to `/data/root/.analyzed/<workflow-uuid>/<timestamp>/`.

**Fail:** read the Slurm log before assuming the measurement is at fault:

```bash
sudo docker compose exec biomeroworker \
  ssh spider "tail -40 ~/omero-<jobid>.log"
```

A `does contain` line for each suffix means matching worked and the fault is
elsewhere. No such lines means the suffixes are wrong.

## Independent checks

These need nothing from the chains beyond P1.

### I1 — StarDist

Same as A1, swapping the workflow. Use `$RGB`, not `$FIG7`.

```text
image       $RGB
workflow    stardist
3c) Rename  {original_file}_Nuclei_Mask.{ext}
```

Set the rename even though this chains into nothing: without it the result imports
as `<name>.ome.tiff.0.tif`, hard to tell from the original in a list.

StarDist branches on 1-channel greyscale vs 3-channel RGB and has no 2-channel
path, so `$FIG7` takes the RGB branch on 2-channel data and the result is not
meaningful. This is a property of the workflow, not a bug in the deployment.

**Pass:** a mask comparable to B1's on the same input.

### I2 — Importer watch path

Independent of the workflow chain. The importer polls its database queue rather
than watching a directory, so a file merely copied into `/data` is *not* picked
up. Queue both reference images from **BIOMERO → Importer** and walk away;
`imports` records the lifecycle:

```text
Import Pending -> Import Started -> Import Completed
```

**Pass:** both images reach `Import Completed` and appear in OMERO with nobody
touching anything after queueing.

### I3 — ZARR format passthrough

`Use_ZARR_Format` in the run dialog is not about the input image being a Zarr.
OMERO always exports to OME-Zarr; the toggle only decides whether that export is
converted to TIFF before the workflow runs:

```text
OFF   zarr -> tiff   CONVERT_ZARR_TO_TIFF runs      (every other test takes this)
ON    zarr -> zarr   conversion is a no-op
```

Of the workflows registered here, every one declares `requires-zarr: false` and
takes TIFF. Only `BilayersTest`, which is not in `slurm-config.ini`, declares
`requires-zarr: true`. So turning the toggle ON hands a Zarr to a workflow that
expects TIFF.

```text
image     $FIG7 (the .ome.tiff, as in A1)
workflow  cellpose, exactly as A1
Use_ZARR_Format   ON
Ome-zarr version  0.4
```

**Pass:** the conversion is a no-op and the run fails in the *workflow* step,
because the registered workflows cannot read Zarr:

```text
IsADirectoryError: [Errno 21] Is a directory:
  .../data/in/fig7_RSAdetection_16w.ome.tiff.zarr
ERROR: Workflow completed without producing files in .../data/out
```

So the toggle does what it says. Leave it OFF for every registered workflow.

Worth knowing when driving this form by script rather than by hand:
`Use_ZARR_Format` is an HTML checkbox, so posting `Use_ZARR_Format=false` turns
it **on** -- any value reads as checked, and only omitting the field leaves it
off. Getting that wrong produces exactly the failure above while every setting
looks correct.

**Fail:** a failure in `SLURM_Remote_Conversion.py` rather than in the workflow
means the no-op conversion path itself is broken, which is a deployment problem
rather than a format mismatch.

Note this tests the *transfer* format, not the registered Zarr images.

#### Running a workflow on a registered Zarr image

This is a separate case and it does not work. Submitting a Zarr-registered image
(one whose pixels OMERO reads in place through `externalinfo`) runs the whole
chain, but cellpose reports `No cell pixels found` with `divide by zero
encountered in true_divide`, and the run fails at 90% in
`SLURM_Import_Results.py`:

```text
Zip file is too small (336 bytes), indicating no meaningful data was transferred
```

The message blames the image export, which is misleading: the export produced a
525 KB TIFF and cellpose wrote a 1280-byte mask. Both the transfer and the
workflow "succeeded". The mask is empty because the exported channel was blank,
and the size check then rejects the zip.

Use the `.ome.tiff` for workflows. The Zarr copies are for viewing and as the
verifiable upstream original; see [reference-data.md](reference-data.md).

## Known trap: workflow dimensionality

Every workflow registered here is 2D-only except `stardist5d`. The cellpose
wrapper calls `prepare_data(..., is_2d=True)`; its padding step builds a 2-entry
pad spec, appends a third only for 3D, and has no 4D case:

```python
for i in range(2): ...
if len(img.shape) == 3:
    padshape.append((0, 0))
img = np.pad(img, padshape, ...)     # 4D input -> ValueError
```

A `(3, 2, 2048, 2048)` stack — Z=3, C=2 — crashes, and because one bad image
aborts the batch, *every* image in that run is lost. `img.shape[:2]` also reads
`(3, 2)` as height and width, so the logic is wrong before it throws.

Both reference datasets are 2D to avoid this. With your own data, check the
dimensions in the image's **Info** panel in **Data** before submitting. If
`sizeZ > 1`, either set `Choose_Z_Section` to **Max projection** in the run
dialog, or use `stardist5d`, which is the only registered workflow that handles
Z and T. No cellpose parameter makes a Z-stack work.

## Not covered

Three registered workflows have no test here, for lack of suitable data:

```text
stardist5d                its purpose is Z/T looping; both reference images are
                          sizeZ=1, sizeT=1
spotcounting              consumes a cell mask and an aggregate mask, paired by
                          the suffixes _C and _A; nothing here produces an
                          aggregate mask
aggregates_measurements   same missing aggregate mask, plus a third _Aggregates_Mask
```

Closing these needs more reference data, not more procedure — see the Gaps
section of [reference-data.md](reference-data.md).

`Cellpose4` is not registered, only classic `cellpose`. Workflows absent from
`web/slurm-config-template.ini` fail at submission, before any Slurm job exists.

## Status

As of 2026-09-17, re-run end to end on a VM rebuilt from an empty volume
(biomeroqa), which is also where the Status column below comes from:

```text
P1  pass      both images render; no dangling links, no pixel-less rows
A1  pass      cellpose on $FIG7, mask imported back into "A1 nuclei"
A2  pass      cell mask in "A2 cells", named _Cells_Mask by the workflow itself
B1  pass      cellpose on $RGB, mask returned at the full 1757x1114
B2  pass      cell mask in "B2 cells"
B3  pass      56 nuclei measured; Nuclei/Cells/Cytoplasm/Experiment/metadata
              tables attached, 56 rows each
I1  pass      stardist on $RGB, mask in "I1 stardist"
I2  pass      both reference images imported unattended from the queue
I3  pass      fails in the workflow, not in conversion, as expected
```

Upstream behaviour these tests surfaced is collected in
[upstream-suggestions.md](upstream-suggestions.md).

## Recording results

The Status block above is where per-check results live; keep it current.

When a check fails, note the workflow UUID from the Analyzer, look it up in
`biomero_workflow_progress_view`, then read `biomero_task_execution` for the
error text. For a failure inside the workflow itself, the Slurm log on Spider
has the traceback:

```bash
sudo docker compose exec biomeroworker ssh spider "tail -40 ~/omero-<jobid>.log"
```

These tests need a browser and live Spider, so nothing runs them
automatically.
