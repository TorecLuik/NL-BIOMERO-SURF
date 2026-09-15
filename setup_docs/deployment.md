# NL-BIOMERO Deployment

Current state of this deployment: what it runs, how it is configured, and how to
rebuild it. This describes how things are, not how they came to be.

## Stack

One host runs the whole stack via `docker-compose.yml`:

```text
omeroserver        OMERO.server
omeroworker-1      OMERO processor
biomeroworker      BIOMERO processor, submits Slurm jobs to Spider
omeroweb           OMERO.web with OMERO.biomero and OMERO.forms
database           OMERO Postgres
database-biomero   BIOMERO analytics and import tracking Postgres
biomero-importer   BIOMERO.importer, runs the converter under rootless Podman
metabase           dashboards embedded in OMERO.web
```

`opensearch-compose.yml` and `logs-compose.yml` are optional and started
separately.

## Versions

Pinned in `.env.shared`, which `.env` overrides locally:

```text
BIOMERO_VERSION           2.8.2
OMERO_BIOMERO_VERSION     1.6.1
BIOMERO_IMPORTER_VERSION  1.4.2
OMERO_FORMS_VERSION       2.3.1
OMERO_ZARR_PIXEL_BUFFER_VERSION 0.6.1
```

Base images: `openmicroscopy/omero-server:5.6.18` for the server and workers,
`openmicroscopy/omero-web-standalone:5.33.1` for web.

`BIOMERO_VERSION` has no `v` prefix; it is passed straight to pip.

## Rebuilding

```bash
scripts/bootstrap-prod.sh              # preflight, deploy, smoke test
scripts/bootstrap-prod.sh --check-only # preflight only
```

The script checks prerequisites, deploys through `scripts/deploy-local-stack.sh`,
then smoke tests services, databases, the web login page, installed versions,
the runtime patch, and Spider reachability.

### Files that cannot be regenerated

```text
.env         deployment secrets; the only copy on this deployment
.env.keys    dotenvx private keys, used with an .env.secrets where one exists
.ssh/        Spider SSH key material
```

There is no `.env.secrets` here, so `.env` itself must be archived. Everything
else in the repo is reproducible from a clean checkout.

## Slurm Job Scripts

`slurm_script_repo` is intentionally blank. BIOMERO generates every job script
from each workflow's `descriptor.json` and uploads it, so job scripts are not
maintained in this repository and no workflow-specific `.sh` files are shipped.

Converter images are likewise built on Slurm rather than pulled. The
`[CONVERTERS]` section pins nothing; uncomment an entry there only if the
cluster lacks Singularity build rights.

Keep it this way. Maintaining local copies of generated scripts or pinned
converter images reintroduces drift between this deployment and upstream.

## GPU Policy

Per workflow in `slurm-config.ini`:

```text
<workflow>_use_gpu = True      marks a workflow GPU-native
<workflow>_job_<flag> = value  becomes --<flag>=value
```

Global fallbacks in `.env.shared`, applied only to flags a workflow has not set:

```text
BIOMERO_INJECT_GPU_FLAG=true
BIOMERO_GPU_PARTITION=gpu_a100_mig
BIOMERO_GPU_GRES=gpu:a100_3g.20gb:1
```

Use `_job_gres`, never `_job_gpus`, for overrides. BIOMERO fills `--gres` and
`--gpus` gaps independently, so a workflow setting only `_job_gpus` still
inherits the global MIG `--gres` and emits both flags, which Spider rejects.

CPU-only workflows carry no `use_gpu` and no partition, so Spider routes them to
its normal default partition.

### Spider GPU resources

```text
gpu_a100_mig  gpu:a100_3g.20gb:4  wn-ga-[01-03]  4 MIG slices, 14 CPUs/node
gpu_a100_22c  gpu:a100:2          wn-gb-[01-05]  full A100
```

MIG VRAM comes from the GRES profile: `gpu:a100_3g.20gb:1` is one CUDA device
with about 20 GB. Requesting two slices gives two separate devices, not one
40 GB device. CPU requests are node-level, so more slices do not multiply the
CPU count.

### Per-workflow GPU assignment

```text
cellpose          full A100   classic container is not MIG-capable: reports
                              cuda True but device_count 0 under MIG
deconvolve_plate  full A100   runs on MIG, but 16 CPUs exceeds the 14-CPU
                              MIG node limit
stardist          CPU only    TF 1.15 container cannot register a GPU; the
stardist5d        CPU only    CUDA 10 / cuDNN 7 libraries are missing
all others        CPU only
```

These follow from the pinned container versions, each of which is already the
latest upstream release. Re-test with a probe job before changing any of them:

```bash
sbatch --partition=gpu_a100_mig --gres=gpu:a100_3g.20gb:1 --cpus-per-task=3 \
  --mem=16G --time=00:05:00 --wrap="singularity exec --nv <sif> \
  python -c 'import torch;print(torch.cuda.is_available(),torch.cuda.device_count())'"
```

## Runtime Patch

One patch remains, applied in both the worker and web images because
OMERO.biomero submits analyzer jobs from the web process:

`biomeroworker/patch_biomero_runtime.py` injects
`biomeroworker/patches/generated_job_postprocess.py`, which appends
`set -eo pipefail` and `_nl_biomero_verify_outputs` to generated job scripts. A
workflow container can print a traceback, exit zero, and leave `data/out` empty;
without the check BIOMERO enters import and hangs around 90%.

The patch is idempotent and fails loudly if upstream moves its anchor. If it
fails after a version bump, check whether upstream now verifies outputs itself
and delete the patch rather than re-anchoring it.

Everything else this deployment needs is upstream configuration:

```text
BIOMERO_ENV_FILE_SUBMISSION     per-job env files, sourced by generated scripts
BIOMERO_IMAGE_PULL_VIA_SBATCH   image pulls run as Slurm jobs, not on the login node
BIOMERO_PULL_CPUS / _MEM        bound those pull jobs
BIOMERO_APPTAINER_TMPDIR        project-local Apptainer temp
BIOMERO_APPTAINER_CACHEDIR      project-local Apptainer cache
BIOMERO_SLURM_ZIP_CMD           unset; the default detects 7z or 7za
slurm_conversion_partition      blank, so conversions use Spider's default
```

## Dependency Constraint

`biomero-importer` pins `ezomero==3.2.3` and `biomero[full]` pins
`ezomero==1.1.1`, so the worker image installs them in two separate pip runs and
lets BIOMERO's pin win. `pip check` reports the mismatch by design.

This is safe: the importer calls only `ezimport`, `get_group_id` and
`post_map_annotation`, all present in 1.1.1, and calls `ezimport` with keyword
arguments, so the `ln_s` parameter dropped in 3.x is not a positional hazard.

BIOMERO 2.9 moves to `ezomero==3.2.3`; when adopting it, collapse the two pip
runs back into one.

## Spider Paths

```text
/project/<project>/Share/biomero/data
/project/<project>/Share/biomero/slurm-scripts
/project/<project>/Share/biomero/singularity_images/workflows
/project/<project>/Share/biomero/singularity_images/converters
```

`scripts/render-slurm-config.sh` renders `web/slurm-config-template.ini` into
`web/slurm-config.ini`, substituting `SPIDER_USER` and `SPIDER_PROJECT` and
setting mode 0666 because OMERO.biomero writes that file from `omeroweb` as
uid 999.

## Verifying a Change

Check the effective Slurm parameters without submitting anything:

```bash
docker compose exec -T biomeroworker /opt/omero/server/venv3/bin/python -c "
from biomero import SlurmClient
c = SlurmClient.from_config()
print(c.get_workflow_command('cellpose', 'latest', 'testdata', {})[0])"
```

Confirm no workflow emits `--gres` and `--gpus` together.
