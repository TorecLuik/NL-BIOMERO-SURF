# Running and Debugging Workflow Runs

How a BIOMERO workflow run fails, and where the real cause lives. The failure a
user reports is usually two steps downstream of the fault.

## Tracing a run

`biomero_task_execution` has no `workflow_id` column. Look the run up in the
progress view first, then read the tasks:

```bash
docker exec nl-biomero-database-biomero-1 psql -U biomero -d biomero -x \
  -c "SELECT * FROM biomero_workflow_progress_view WHERE workflow_id='<uuid>';"

docker exec nl-biomero-database-biomero-1 psql -U biomero -d biomero -x \
  -c "SELECT task_name, status, error_type, start_time, end_time
      FROM biomero_task_execution ORDER BY start_time DESC LIMIT 10;"
```

For a fault inside the workflow container, the Slurm log has the traceback:

```bash
docker exec nl-biomero-biomeroworker-1 ssh spider "tail -40 ~/omero-<jobid>.log"
```

That log is also attached to the dataset in OMERO after the run, so it survives
Spider-side cleanup.

## Misleading failures

**`SLURM_Remote_Conversion.py: "Input data": biomero_<uuid> not in [...]`**
The ZARR export failed and the transfer task still reported `CREATED`, so no
folder was ever created on Spider. The message names the missing folder, not the
fault. Real cause in `biomero.log`:

```bash
docker exec nl-biomero-biomeroworker-1 \
  grep -i "Critical error\|ResourceError" \
  /opt/omero/server/OMERO.server/var/log/biomero.log | tail
```

**`Zip file is too small (336 bytes) ... check SLURM_Image_Transfer logs`**
Usually the export was fine and the workflow produced an empty result. Check the
sizes on Spider before believing the message: an input of a few hundred KB with a
~1 KB output means the workflow ran and segmented nothing.

**`ApiUsageException: Invalid C index: 1/1`**
OMERO's channel count disagrees with what Bio-Formats reads from the file. For a
hand-built OME-TIFF this usually means the OME metadata is missing entirely --
`tifffile` only writes it when the output path ends `.ome.tiff`.

**Workflow `DONE` at 100% but no results in OMERO**
The Slurm job succeeded and `SLURM_Import_Results.py` failed afterwards. See
below.

## Results that never reach OMERO

`SLURM_Import_Results.py` runs the importer path first, and it is fatal:

```python
if use_importer_for_datasets or use_importer_for_screens:
    process_importer_workflow(...)   # sys.exit(1) if no image files found
logger.info("Creating metadata CSV...")
if process_csv_tables:
    process_slurm_tables(...)        # never reached after that exit
```

So a workflow producing only CSVs -- any CellProfiler measurement -- aborts
before its tables are attached, whenever a dataset is selected under
*Add (mask) image results to a dataset*. The tell in the script's stdout:

```text
CRITICAL: No image files found for importer processing - workflow failed!
```

That option has no toggle: it is on whenever a dataset is selected, so it is
turned off by clearing the dataset chip. The UI marks it *Suggested* even for
workflows whose descriptor declares no image outputs.

Results always land on the server regardless:

```text
/data/root/.analyzed/<workflow-uuid>/<timestamp>/
```

## Workflow inputs

**Suffix matching** is on a substring, so the `.0.tif` extensions a round trip
accumulates do not break it. The Slurm log prints a `does contain` line per
suffix, which separates a naming failure from a pipeline one.

Chaining relies on `3c) Rename the imported images`. CellExpansion is the
exception: it names its output by replacing the literal substring `Nuclei` with
`Cells`, so its rename must be left empty or input and output collide.

**Channel count** is not just a parameter. The CellProfiler measurement pipeline
loads the original through `NamesAndTypes` as a colour image and needs three
channels; on a 2-channel image it fails with `cannot reshape array of size N`.
`metric_channels` reconfigures which channels are measured, not how the image is
loaded, so it does not help.

**Registered vs listed.** The Analyzer lists every workflow in the descriptor
catalog, not only those in `biomeroworker/slurm-config.ini`. A workflow that is
listed but not registered fails at submission, before any Slurm job exists:

```bash
grep -E "^[a-z0-9_]+_repo=" biomeroworker/slurm-config.ini
```

**ZARR.** `Use_ZARR_Format` is not about the input being a Zarr: OMERO always
exports to OME-Zarr, and the toggle only decides whether that export is
converted to TIFF. Every registered workflow here declares `requires-zarr:
false`. Submitting a Zarr-registered image (one read in place through
`externalinfo`) runs the whole chain and produces an empty mask.

## Image inputs that look fine and are not

```bash
# by-reference imports whose source has gone
docker exec nl-biomero-omeroserver-1 bash -lc \
  'find /OMERO/ManagedRepository -type l ! -exec test -e {} \; -print'

# pixel-less images; plate wells legitimately match, so exclude well samples
docker exec nl-biomero-database-1 psql -U omero -d omero \
  -c "SELECT i.id, i.name FROM image i JOIN pixels p ON p.image=i.id
      WHERE i.fileset IS NULL AND p.path IS NULL
        AND NOT EXISTS (SELECT 1 FROM wellsample ws WHERE ws.image=i.id);"
```

A Zarr image legitimately has no fileset and no pixels path -- it is registered
by external reference -- so judge it by whether it previews. A Zarr showing
`No preview` has an incomplete pyramid: OMERO opens every path in the
`multiscales` list, and a missing level gives
`'.zarray' expected but is not readable or missing in store`, surfacing as a
`getTileSize` InternalException in iviewer.

One bad image aborts a whole batch, so never submit a selection containing one.

Fixing a Zarr on disk fixes its OMERO image, because the registration is only a
pointer. A TIFF is not like this: its channel count is read into the database at
import time, so a file corrected afterwards must be re-imported.
