# Upstream Suggestions

*Created 2026-09-17 · last updated 2026-09-17*

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

## 7. Duplicate `biomero-importer` entries in `.gitmodules`

**Repo:** NL-BIOMERO

Fetching the upstream repository warns on an ancestor commit:

```text
warning: <commit>:.gitmodules, multiple configurations found for
'submodule.biomero-importer.path'. Skipping second one!
warning: <commit>:.gitmodules, multiple configurations found for
'submodule.biomero-importer.url'. Skipping second one!
```

`.gitmodules` declares `submodule.biomero-importer` twice. Git resolves this
silently by taking the first and discarding the second, so the submodule can
resolve to a different path or URL than the file appears to specify. Harmless
until the two entries disagree, at which point the checkout is wrong with no
error.

**Suggested:** collapse the duplicate to a single entry.

## 8. The worker's SSH handling cannot work as shipped

**Repo:** NL-BIOMERO (`biomeroworker/10-mount-ssh.sh`, `docker-compose.yml`)

The container cannot mount an SSH directory directly, because host permissions
do not suit the container user. The shipped answer is to mount it at `/tmp/.ssh`
and have the entrypoint copy it into place:

```yaml
- "~/.ssh:/tmp/.ssh:ro"
```

```bash
if [[ -d /tmp/.ssh ]]; then
  cp -R /tmp/.ssh /opt/omero/server/.ssh
  chmod 700 /opt/omero/server/.ssh
  chmod 600 /opt/omero/server/.ssh/*
```

Four problems, all reproducible:

**The whole of `~/.ssh` goes into the container.** The worker needs one cluster
key. It receives every key the operator owns, plus their `config` and
`known_hosts`. A compromise of the worker is a compromise of every host that
user can reach, and on a shared VM the mount silently widens as the operator
adds keys for unrelated work.

**The copy nests on restart.** `cp -R src dst` creates `dst` on the first run,
but copies *into* it on every run after, so a restart produces
`/opt/omero/server/.ssh/.ssh/`:

```text
run 1   /opt/omero/server/.ssh/id_rsa
run 2   /opt/omero/server/.ssh/id_rsa
        /opt/omero/server/.ssh/.ssh/id_rsa
```

The stale outer copy still resolves, so the worker keeps running on the key from
whenever the container was first created, and a rotated key appears not to take
effect. The script's own `TODO: error on windows ? this didn't copy 'config'` is
the same bug seen from the other side.

**The permissions are unsatisfiable on the host side.** The container reads the
mount as "other", so the key needs group or world read; OpenSSH refuses any
private key with a group or other bit set, *even when the group is the owner's
own*. One file therefore cannot serve both the container and ordinary `ssh` on
the host. Tested and rejected here: a single `0640` key (`WARNING: UNPROTECTED
PRIVATE KEY FILE!`, key ignored), and `group_add` with the directory at `0700`
(owner bits are all that matter). The only arrangements that work are a
world-readable key, or two copies at different modes -- this deployment mounts a
separate `.ssh-worker` at `0640` and keeps `.ssh` at `0600`.

**Nothing fails loudly.** A key the container cannot read stops the worker with
`cp: cannot stat '/tmp/.ssh/.': Permission denied` and exit 1, which surfaces
only as an absent service; the nesting case does not fail at all.

**Suggested:** mount a single named key rather than a directory, via a build arg
or a Docker secret; replace `cp -R src dst` with `rm -rf dst && mkdir -p dst &&
cp -R src/. dst/` so restarts are idempotent; and let the worker run as a uid
that can read a `0600` mount, which removes the permission conflict instead of
trading it for a second copy of the secret.

## 9. An empty ID list reaches OMERO as `in ()` and fails the import

**Repo:** BIOMERO (`SLURM_Import_Results.py`)

A cellpose run on 2026-09-17 (`c92ea552-74ff-4713-8c07-834cc806ecaa`) finished
on Slurm, produced its mask, and then failed at 90% in the import step:

```text
ApiUsageException: unexpected end of subtree
  [select obj from ome.model.core.Image obj ... where obj.id in ()]
  nested exception is org.hibernate.hql.ast.QuerySyntaxException
```

The workflow itself was fine. The Slurm log ends `Job completed successfully`,
and the 1.9 MB mask is in `.analyzed/<uuid>/<ts>/`. Nothing reached OMERO: no
image was created after the run started, so the results exist only on disk.

The query is built from an empty ID list. `findAllByQuery` is called with
`where obj.id in (:ids)` and an `RList` whose `_val` is empty, which OMERO
renders as `in ()` and Hibernate rejects. An empty list is a legitimate outcome
here -- the workflow may match nothing -- so it should short-circuit to "no
images" rather than be sent to the server as a malformed query.

What is odd, and unresolved: the IDs were recorded. The import task carries
`input_data: {"IDs":[756]}` in `workflowtracker_events`, image 756 still exists,
and it is in the same group and owner (`system`/`root`) the script ran as. So
the list is empty at the call site despite being populated in the task, and the
failure is 23 ms after the results are extracted -- too fast for a lookup to
have been attempted and come back empty. The guarded paths in the script log
`No input IDs available...` when they find nothing, and that line is absent, so
this is a different call site that never checks.

This is the same family as item 1: the script does not treat "no images" as a
normal outcome. There it exits with `CRITICAL: No image files found`; here it
passes the empty list to the server.

**Suggested:** return early when the ID list is empty instead of building a
query from it, and log the list and its origin at that point so the empty case
is diagnosable. More generally, treat an empty image set as a valid result
throughout the script rather than an error or an unchecked value.

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

Item 9 is the one with a live cost: a workflow that runs correctly on Slurm
still reports FAILED and leaves its results on disk, so it looks like a compute
failure and is not. It is unresolved here -- the IDs are recorded on the task
but the query is built from an empty list -- and the report should ask where
that list is read, since this deployment cannot see the call site.

Item 8 is the one to raise first for anyone deploying outside a developer
laptop: it cannot be worked around without either exposing the cluster key to
every account on the host or keeping two copies of it, and its failure modes are
a container that exits with one line of output and a key rotation that silently
does not take.
