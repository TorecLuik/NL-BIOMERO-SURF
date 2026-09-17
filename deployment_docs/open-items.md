# Open Items

*Created 2026-09-15 · last updated 2026-09-17*

Work in progress on `prod-rebuild-2026-09`: what is still open, and what the
rebuild changed. Delete entries as they close, and delete this file once the
branch merges. For how the deployment is configured, see
[deployment.md](deployment.md).

## Blocking

**Archive the secret files.** They exist only on this VM and are in no backup:

```text
.env         deployment secrets; the only copy
.ssh/        Spider SSH key material
```

Losing `.env` means reconstructing every secret by hand. Archive all three,
encrypted, off this VM. Nothing else should be treated as done until this is.

The automated snapshot was refused by a credential-safety guard, so this has to
be done by hand.

## Not Yet Verified

Everything below needs real data, a browser, or a fresh machine, so none of it
is covered by the automated smoke tests:

```text
the /logs viewer rendering behind nginx basic auth
OMERO.insight connectivity on 4063/4064
```

The end-to-end workflow run is no longer among them; see below. The procedures
and public test data are in [pipeline-tests.md](pipeline-tests.md) and
[reference-data.md](reference-data.md), which tracks which of its checks have
been run.

Two items closed on 2026-09-17 by rebuilding `biomeroqa` from an empty volume:

*The bare-VM sequence.* `make provision` through `make deploy` was run twice
from nothing -- no repo, no images, no containers, an empty storage volume --
following SETUP.md as written. It failed the first time in eight distinct
places, every one of them invisible on a machine that had deployed before; the
fixes are on this branch. The second run, against the fixed tree, is what the
Status block in pipeline-tests.md reports.

*The importer.* All nine checks in pipeline-tests.md now pass there, including
I2 and I3, which had never been run. Note what the importer actually does:
it polls its database for queued orders rather than watching a directory, so
a file copied into `/data` is not picked up on its own.

Three registered workflows (`stardist5d`, `spotcounting`,
`aggregates_measurements`) cannot be tested at all with the current two
reference images: one needs a Z-stack or time series, the other two need an
aggregate mask that nothing here produces. Gaps are listed in
[reference-data.md](reference-data.md).

Both remaining items need something outside the VM: the Research Cloud portal
for 4063/4064, and a browser pointed at `/logs` with the basic-auth credentials
`make logs-auth` wrote.

## Planned

Turning the deployment into a Research Cloud catalog item, so that creating a
workspace replaces most of `new-vm.md`. Scoped in
[catalog-item-migration.md](catalog-item-migration.md), not started. Five open
questions there need answering before any component is written.

## Then

Provision the replacement prod VM, run `scripts/bootstrap-prod.sh` on it from a
bare state, work through the list above, and merge `prod-rebuild-2026-09`.

## Rollback

```bash
git checkout prod-known-good-2026-09-15   # a8b76d3c
```

Restore commands are in `/data/storage_hpc/biomero-backup-2026-09-15/MANIFEST.md`.
That backup holds both Postgres volumes, the OMERO data volume, the Metabase H2
database and stack configs. It does not hold the secret files above.

## What Was Done

Branch `prod-rebuild-2026-09`, off `spider-review`.

**Backed up the previous state.** Tag `prod-known-good-2026-09-15` (`a8b76d3c`)
on origin, plus both Postgres volumes, the OMERO data volume, Metabase H2 and
stack configs in `/data/storage_hpc/biomero-backup-2026-09-15`, verified by
checksum before anything was changed. Pruned stale Docker images, containers and
anonymous volumes to make room for builds; the root filesystem went from 11 GB
free to 44 GB.

**Upgraded the stack.**

```text
BIOMERO_VERSION           v2.5.3   -> 2.8.2     (prefix dropped; passed to pip)
OMERO_BIOMERO_VERSION     1.3.2    -> 1.6.1
BIOMERO_IMPORTER_VERSION  1.2.1    -> 1.4.2
OMERO_FORMS_VERSION       2.2.0    -> 2.3.1
omero-server base         5.6.17   -> 5.6.18
omero-web-standalone base 5.31.1   -> 5.33.1
```

**Retired the runtime patches.** 9 of 13 patch anchors no longer exist in 2.8.2
because upstream absorbed them as configuration. They were replaced with
upstream settings rather than re-anchored, and the GPU policy moved from
`BIOMERO_*_<WORKFLOW>` env overrides to per-workflow keys in `slurm-config.ini`.
The Metabase web patch was dropped too: OMERO.biomero 1.6.1 ships the same
localhost rewrite. Only output verification is still patched.

**Removed local workflow overrides.** Five unreferenced job scripts under
`biomeroworker/patches/jobs/` were deleted. BIOMERO generates every job script
from each workflow's descriptor, and converter images are built on Slurm.

**Added `scripts/bootstrap-prod.sh`.** Preflight, deploy, smoke test in one
command.

**Narrowed what travels with the volume.** An earlier layout kept `.env`,
`.ssh/` and `slurm-config.ini` in `config/` on the storage volume and symlinked
the repository at them. Only what is fixed by the data belongs there, which is
`volume-identity` alone:

- `.env` and `.ssh/` are per-VM. A fresh VM adopting a volume's `.env` silently
  inherited the previous machine's hostname and pins, and the two copies drifted
  with nothing to say which was authoritative. `deploy-local-stack.sh` no longer
  links them, and the stale copies were deleted from this volume.
- `slurm-config.ini` is rendered from the committed template plus `.env`, so it
  is reproducible rather than state. It sat on the volume because the
  OMERO.biomero admin UI rewrites it; those edits are now deliberately
  transient. `make link-config` became `make render-config`.

### Problems found along the way

Upstream behaviour that is not fixable here is collected in
[upstream-suggestions.md](upstream-suggestions.md).

- Two cellpose runs failed on 2026-09-16, neither caused by the rebuild: one fed
  a `(3,2,2048,2048)` stack to a 2D-only workflow, the other ran on a
  by-reference image whose source had been deleted. Both failure modes, and how
  to avoid them, are in [pipeline-tests.md](pipeline-tests.md).
- Images 51 and 257 (`7-1.czi`) were deleted as unrecoverable: imported by
  reference from `/data/fig7_RSAdetection_16w/`, which no longer exists, and the
  2026-09-15 backup had archived the dangling symlinks rather than the pixels.
  Public replacements are in [reference-data.md](reference-data.md).
- A transfer task that fails during ZARR export still reports CREATED, so the
  error surfaces two steps later as a misleading
  `SLURM_Remote_Conversion.py` ValidationException. Upstream behaviour, not
  configuration; [pipeline-tests.md](pipeline-tests.md) says where the real
  cause is logged.
- Metabase filled `metabase.db.trace.db` at ~2.5 GB/day on 2026-09-17: an empty
  `metabase/metabase.db/` directory sat where H2 creates its store, so H2
  retried the lock forever while still serving 200s. Rather than patch the H2
  layout, Metabase was migrated to a `metabase` database on `database-biomero`,
  which removes the failure mode entirely and puts the dashboards inside a
  backed-up volume. `load-from-h2` preserved dashboard IDs 2 and 6, so the
  OMERO.web embeds still resolve and `.env` needed no change. The source was the
  2026-09-15 backup `metabase-h2.tar.gz`, which verified against its SHA256SUMS.
  `make doctor` now checks the Postgres setup and both embedded dashboard IDs.
  `metabase/metabase.db/` is leftover and can be deleted once you are satisfied.
- The BIOMERO Importer v1.4.2 hardcodes `--transfer=ln_s`, so every image it
  imports is a symlink into `/data` and its pixels are outside the volume
  backup. 40 such links exist here, none broken yet; workflow results link into
  `/data/root/.analyzed/`, which is scratch. No setting changes this. Use
  OMERO.insight for anything that must survive. Detail in the expert skill under
  "The Importer Always Links, Never Copies".
- The reference Zarrs were fetched with only pyramid level 0 while their
  `.zattrs` declared three, so OMERO's NGFF pixel buffer failed on the missing
  level and both registered without a readable pixel or a thumbnail. Levels 1
  and 2 are now fetched too. Zarr import by external reference works; it was the
  incomplete pyramid that did not.
- A single `pip install` of `biomero-importer` and `biomero[full]` fails with
  ResolutionImpossible over conflicting ezomero pins. The two-step install is
  deliberate; see `deployment.md`.
- Upstream fills `--gres` and `--gpus` independently, so a workflow setting only
  `_job_gpus` still inherits the global MIG `--gres` and emits both, which
  Spider rejects. Overrides use `_job_gres`. Caught by simulating the upstream
  parser before building.
- The previous prod image ran biomero 2.7.0 and importer 1.3.0, not the 2.5.3
  and 1.2.1 that `.env.example` claimed. The ignored local `.env` was the real
  source of truth. Both files now agree.

## Verified

On the dev VM against live Spider:

```text
pipeline import -> Spider -> Slurm -> results back in OMERO, in the browser,
         on both reference images: cellpose segmentation, CellExpansion, and
         stardist, and CellProfiler quantification returning OMERO.tables.
         Per-check status is in pipeline-tests.md; the importer watch path
         and the ZARR passthrough are still open.
builds   both images build from a clean checkout
worker   biomero 2.8.2, biomero-importer 1.4.2, zarr 3.1.5, ezomero 1.1.1
web      omero-biomero 1.6.1, biomero 2.8.2, omero-forms 2.3.1, omero-web 5.33.1
stack    all 8 services up; both databases queryable; web login responds on :4080
         output-verification patch present in worker and web
         worker reaches Spider Slurm from inside the container
config   SlurmClient.from_config() loads every retired patch as upstream setting
slurm    scripts generated from descriptors; no local job scripts
gpu      cellpose --partition=gpu_a100_22c --gres=gpu:a100:1
         deconvolve_plate  same
         everything else   no partition, Spider default
         no workflow emits --gres and --gpus together
jobs     full-A100, MIG and CPU-only probe jobs all COMPLETED on Spider
logs     OpenSearch green, Dashboards serving /logs, Fluent Bit indexing;
         biomero-logs holds ~51M docs going back to June
```

GPU assignments were re-tested rather than carried over. All GPU-relevant
workflow containers are already pinned to their latest upstream releases, and
classic cellpose on a MIG slice still reports `cuda True` with `device_count 0`,
so its full-A100 pin stands.

## Found by the fresh-VM rebuild (2026-09-17)

`biomeroworker/slurm-config.ini` is baked into the image at
`/etc/slurm-config.ini`, which is *first* in BIOMERO's config search path. It
holds upstream's local-dev defaults -- `host=localslurm`, `/data/my-scratch/...`
-- none of which apply here. It is harmless today only because configparser
merges the search path in order and the bind-mounted
`web/slurm-config.ini` happens to define every key it defines, so every value is
overridden. Verified: zero keys currently leak through.

That safety is accidental. Any key added to the baked copy, or removed from the
template, silently takes effect with a local-dev value. The deploy bind-mounts
the authoritative config unconditionally, so the `COPY` at
`biomeroworker/Dockerfile:74` can go; it needs a worker image rebuild to verify.
