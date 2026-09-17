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

`ROI_Target_Image_IDs` is declared `optional=True` with no default, and the
script reads it without checking:

```python
_roi_target_ids = unwrap(client.getInput(ROI_TARGET_IMAGE_IDS)) or []
input_images = [
    img for img in conn.getObjects("Image",
        ids=[int(i) for i in _roi_target_ids])
    if img
]
```

The producer is in the same repository, at the same tag.
`SLURM_Run_Workflow.py` forwards the parameter only inside
`if selected_output.get(OUTPUT_CREATE_ROIS)`; its `else` branch sets
`OUTPUT_CREATE_ROIS` false and forwards nothing:

```python
        inputs[constants.results.ROI_TARGET_IMAGE_IDS] = rlist(
            [rlong(image_id) for image_id in target_image_ids])
    else:
        inputs[constants.results.OUTPUT_CREATE_ROIS] = rbool(False)
```

So a run without ROIs reaches the consumer with nothing set, `unwrap` returns
`None`, `or []` makes it an empty list, and `getObjects` is called with
`ids=[]`. This runs unconditionally on every successful extraction, before any
of the code that would have found the IDs elsewhere: the task-based fallback
sits about ten lines below it and never executes.

`SLURM_Get_Results.py` reads the parameter the same unguarded way, so the same
failure is reachable through it.

**This is live in the current stable release.** `biomero 2.8.2` is the newest
version on PyPI, as are `omero-biomero 1.6.1` and `biomero-importer 1.4.2`, so
a deployment installing the latest of everything today gets this. The fix
exists only on the unreleased 2.9 line, where the call has been replaced by a
helper that returns early:

```python
def get_images_in_id_order(conn, image_ids):
    requested_ids = [int(image_id) for image_id in image_ids]
    if not requested_ids:
        return []
```

So the defect is bounded on both sides: `ROI_Target_Image_IDs` does not exist
in v2.7.0, and 2.9 guards it. 2.8.x is the only line that both declares the
parameter and reads it unchecked -- and it is the line users get by default.

This is not a mispairing on our side. `omero-biomero 1.6.1` requires
`biomero<3,>=2.8.2`, so 2.8.2 is what its own constraint selects; the `biomero`
package pins no scripts version, so the scripts tag follows the library
version. Upstream NL-BIOMERO's own releases skip 2.8.x -- `v2.7.0` through
v1.8.0-beta.1, then `2.9.0b6` -- which is likely why the gap went unnoticed,
but it does not make 2.8.2 a wrong choice for anyone installing from PyPI.

The runs on this deployment split exactly on the version rather than on options
or data:

```text
v2.7.0   09-17 09:52 .. 11:07   cellpose, stardist, cellexpansion, ...   DONE
v2.8.2   09-17 16:51           cellpose c92ea552                        FAILED
v2.8.2   09-17 17:46           cellpose 7f4ca095                        FAILED
```

Both 2.8.2 runs fail identically, and no run on 2.8.2 has succeeded. Both had
`Create_ROIs: False` and `Output - Add as attachment to original images: False`,
which is the ordinary configuration for a segmentation workflow writing masks to
a dataset.

**Suggested:** backport the 2.9 guard to the 2.8 line and release it. The fix
is already written and needs no design -- `get_images_in_id_order`, or simply
returning early when the list is empty, as the three other ID-resolving paths
in the same script already do. What matters is that it ships somewhere users
can install: until a 2.8.3 exists, every deployment on the current stable
release fails every workflow run without ROIs, and the error names neither the
parameter nor the script line. Yanking 2.8.2 would work too, but leaves 2.7.0
as the newest stable, which predates the parameter entirely.

## 10. The importer image always installs itself as version 0.0.0

**Repo:** BIOMERO.importer (`Dockerfile`)

The image reports `biomero-importer 0.0.0` no matter which tag is checked out.
Here the submodule sits exactly on `v1.4.2`, and the installed package still
says `0.0.0`, so `make doctor` reports a mismatch against the pin that the
source does not actually have.

The version is `dynamic` via `setuptools_scm`, and the Dockerfile picks between
real metadata and a fallback with:

```dockerfile
RUN if [ -d "/auto-importer/.git" ]; then \
        git config --global --add safe.directory /auto-importer && \
        pip install /auto-importer; \
    else \
        SETUPTOOLS_SCM_PRETEND_VERSION=0.0.0 pip install /auto-importer; \
    fi
```

`-d` tests for a directory. In a git submodule -- which is how NL-BIOMERO
consumes this repository -- `.git` is a *file* holding a `gitdir:` pointer:

```text
$ file biomero-importer/.git
biomero-importer/.git: ASCII text
$ cat biomero-importer/.git
gitdir: ../.git/modules/biomero-importer
```

So the test is false for every submodule build and the fallback always wins.
Changing `-d` to `-e` is not enough on its own: the pointer resolves outside
the build context, so the git metadata is not there to read either.

**Suggested:** accept the version as a build argument, defaulting to the current
fallback, so a consumer that knows which tag it checked out can pass it:

```dockerfile
ARG BIOMERO_IMPORTER_VERSION=0.0.0
RUN SETUPTOOLS_SCM_PRETEND_VERSION=${BIOMERO_IMPORTER_VERSION} pip install /auto-importer
```

That removes the `.git` probe entirely and works the same for a plain clone, a
submodule, and a context with no git at all. Without it, no consumer can build
an image that knows its own version, and any check comparing the installed
version against a pin has to be disabled or special-cased.

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

Item 9 is the one to report first, and the only one that is live in a current
stable release rather than a local choice: biomero 2.8.2 is the newest on PyPI,
every workflow run without ROIs fails under it, and the fix is already written
on the unreleased 2.9 line. A workflow that ran correctly on Slurm still
reports FAILED with its results left on disk, so it reads as a compute failure
and is not. The ask is a 2.8.3, not a diagnosis.

Item 8 is the one to raise first for anyone deploying outside a developer
laptop: it cannot be worked around without either exposing the cluster key to
every account on the host or keeping two copies of it, and its failure modes are
a container that exits with one line of output and a key rotation that silently
does not take.
