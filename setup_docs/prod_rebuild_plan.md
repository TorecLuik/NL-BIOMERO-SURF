# Production Rebuild Plan (2026-09)

Goal: a backed-up known-good state plus a reproducible, up-to-date, validated
stack from which the production VM can be recreated easily.

Branch: `prod-rebuild-2026-09`, based on `spider-review`.

## Findings That Shape This Plan

### Patch anchors vs upstream BIOMERO

All 13 `_replace_required` anchors in `biomeroworker/patch_biomero_runtime.py`
were tested against real wheels:

```text
biomero 2.5.3 (current prod): 13 ok /  0 broken
biomero 2.8.2 (target):        4 ok /  9 broken
biomero 2.9.0b7 (beta):        2 ok / 11 broken
```

The 9 breakages on 2.8.2 are because upstream absorbed the behavior as real
configuration keys, not because of incidental refactoring. Confirmed against
`docs/configuration-reference.rst` shipped in the 2.8.2 wheel.

| Hand-rolled patch | Upstream replacement |
| --- | --- |
| `7z`/`7za` fallback | `slurm_zip_cmd`, default `$(command -v 7z \|\| command -v 7za)` |
| per-job env files | `env_file_submission` |
| conditional `--nv` and GPU params | `inject_gpu_flag`, `gpu_partition`, `gpu_gres`, `gpu_gpus` |
| pulls via Slurm, not login node | `slurm_image_pull_via_sbatch`, `image_pull_cpus`, `image_pull_mem` |
| project-local Apptainer dirs | `apptainer_tmpdir`, `apptainer_cachedir` |
| `mkdir -p` idempotency | now upstream default |
| blank conversion partition | now truthiness-checked, not `is not None` |

Upstream also enforces the Spider GRES/GPUS mutual exclusion in the
`SlurmClient` constructor.

### Version pins

`.env.shared` (production) is on the older pins. The note in
`prod_stack_upgrade_approach.md` that `biomero==v2.7.0` "was not found on PyPI"
was a Python version issue, not a missing release: everything >= 2.7.0 requires
Python >= 3.11 and this dev VM's system Python is 3.10. Inside the container
images this is fine.

### Resources

```text
docker reclaimable: ~53 GB (38.8 GB images, 12.8 GB volumes, 2.4 GB cache)
/data/storage_hpc:  100 GB free, separate disk, used for backups
Spider:             reachable; gpu_a100_mig (3 nodes) and gpu_a100_22c (5 nodes) idle
```

## Target Versions

```text
BIOMERO_VERSION           v2.5.3   -> 2.8.2
OMERO_BIOMERO_VERSION     1.3.2    -> 1.6.1
BIOMERO_IMPORTER_VERSION  1.2.1    -> 1.4.2
OMERO_FORMS_VERSION       2.2.0    -> 2.3.1
omero-server base         5.6.17   -> 5.6.18
omero-web-standalone base 5.31.1   -> 5.33.1
```

## Phases

### Phase 1: Back up the known-good state

Nothing destructive happens before this completes and verifies.

1. Commit pending changes, tag `prod-known-good-2026-09-15`, push tag and
   branch to `origin`.
2. Snapshot ignored runtime files (`.env`, `.env.keys`, `.ssh/`,
   `web/slurm-config.ini`) to an encrypted archive on `/data/storage_hpc`.
   Never commit these in plaintext.
3. Dump both Postgres databases, the Metabase H2 database, and a `MANIFEST.md`
   recording current image digests and exact rebuild commands.
4. Verify the backup by checksum and test-decrypt before any pruning.

### Phase 2: Reclaim disk

Prune stale containers, images, and build cache only after Phase 1 verifies.
Keep the current `nl-biomero-*` images until validation passes; they are the
rollback path.

### Phase 3: Upgrade and retire patches

One behavior per commit so regressions bisect cleanly.

1. Bump pins in tracked `.env.shared`, including base images.
2. Translate each retired patch into upstream configuration in
   `web/slurm-config-template.ini` and env.
3. Keep the shims that upstream does not cover:
   - output verification (`nl_biomero_verify_outputs`)
   - per-workflow Spider GPU policy
   - local job scripts upstream `slurm-scripts` does not ship
4. Re-check the `zarr < 3` pin. 2.8.2 requires `zarr==3.1.5`, so the ordering
   comment in `biomeroworker/Dockerfile` is likely obsolete.

### Phase 4: Bootstrap script

`scripts/bootstrap-prod.sh` takes a bare VM to a running stack in one command:
prerequisite checks, decrypt env via the existing dotenvx flow, render
`slurm-config.ini`, write SSH material, build, up, smoke tests.

### Phase 5: Validate

Full rebuild, then the smoke tests from `prod_stack_upgrade_approach.md`:

```text
CPU-only workflow
MIG GPU workflow
full-A100 workflow (deconvolve_plate)
image pull/build initialization
workflow output import back into OMERO
BIOMERO importer path through /data
OMERO.web login and forms startup
Metabase dashboard embedding
```

Real Spider jobs, not simulations.

## Open Risks

- `deconvolve_plate` GPU override: upstream `gpu_gres`/`gpu_gpus` are a single
  global fallback pair. The per-workflow overrides
  (`BIOMERO_GPU_GRES_DECONVOLVE_PLATE=none` for full A100) have no direct
  upstream equivalent, so that part of the patch likely survives. Confirm in
  Phase 3 rather than assume.
- OMERO.biomero 1.3.2 -> 1.6.1 is a three-minor jump and
  `web/patch_biomero_web_runtime.py` targets it. Treat as its own validation
  step.

## Rollback

```text
git checkout prod-known-good-2026-09-15
restore encrypted env snapshot from /data/storage_hpc
restore database dumps
rebuild from pinned Dockerfiles
```

## Validation Results (2026-09-15)

Executed on the dev VM against live Spider.

### Builds

```text
nl-biomero-biomeroworker  biomero 2.8.2, biomero-importer 1.4.2, zarr 3.1.5, ezomero 1.1.1
nl-biomero-omeroweb       omero-biomero 1.6.1, biomero 2.8.2, omero-forms 2.3.1,
                          omero-web 5.33.1, ezomero 3.2.3
```

Both images build from a clean checkout. The only pip warning is the documented
ezomero mismatch in the worker, which is by design.

### Stack

All 8 services start and stay up: metabase, biomero-importer, biomeroworker,
database, database-biomero, omeroserver, omeroweb, omeroworker-1.

```text
[ok] OMERO database accepts queries
[ok] BIOMERO database accepts queries
[ok] OMERO.web login page responds on :4080
[ok] output-verification patch present in worker and web
[ok] worker reaches Spider Slurm from inside the container
```

### Upstream settings load correctly

`SlurmClient.from_config()` inside the running worker:

```text
inject_gpu_flag            True
gpu_partition              gpu_a100_mig
gpu_gres                   gpu:a100_3g.20gb:1
gpu_gpus                   None
env_file_submission        True
image_pull_via_sbatch      True
apptainer_tmpdir           /project/biomero/Share/biomero/.apptainer_tmp
slurm_conversion_partition None
use_gpu map                {'cellpose': True, 'deconvolve_plate': True}
```

### Generated Slurm parameters

From the real client, not a simulation:

```text
cellpose          --partition=gpu_a100_22c --gres=gpu:a100:1
deconvolve_plate  --partition=gpu_a100_22c --gres=gpu:a100:1
cellexpansion     (none: Spider default partition)
```

No workflow emits `--gres` and `--gpus` together.

### Real Spider jobs

All three policies submitted and COMPLETED:

```text
41197941 nlb-val-a100 COMPLETED  cpu=8,gres/gpu:a100=1,gres/gpu=1,mem=16G
41197942 nlb-val-mig  COMPLETED  cpu=3,gres/gpu=1,mem=16G
41197943 nlb-val-cpu  COMPLETED  cpu=2,mem=4G
```

### Still to verify with real data

These need images and a browser, so they are not covered above:

```text
end-to-end workflow run with results imported back into OMERO
BIOMERO importer picking up files under /data
Metabase dashboard embedding in OMERO.web
OMERO.insight connectivity on 4063/4064
```
