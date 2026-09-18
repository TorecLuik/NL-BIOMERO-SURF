# Slurm Integration and GPU Policy

How this deployment drives Spider/Slurm through BIOMERO, and the one runtime
patch it still carries.

## Runtime Patch

`biomeroworker/patch_biomero_runtime.py` injects
`biomeroworker/patches/generated_job_postprocess.py` into
`biomero/slurm_client.py`, appending `set -eo pipefail` and
`_nl_biomero_verify_outputs` to descriptor-generated job scripts.

It exists because a workflow container can print a traceback, exit zero, and
leave `data/out` empty. Without the check, BIOMERO enters import and hangs
around 90%. Failures instead surface as:

```text
ERROR: Workflow output directory does not exist
ERROR: Workflow completed without producing files
```

Applied in both the worker and web images, because OMERO.biomero submits
analyzer jobs from the web process. It is idempotent and raises if its anchor is
missing. If it fails after a version bump, check whether upstream verifies
outputs itself and delete the patch rather than re-anchoring it.

## Upstream Configuration

Everything else this deployment needs is BIOMERO configuration, not patches:

```text
BIOMERO_INJECT_GPU_FLAG         conditional --nv and GPU sbatch resources
BIOMERO_ENV_FILE_SUBMISSION     per-job env files, sourced by generated scripts
BIOMERO_IMAGE_PULL_VIA_SBATCH   image pulls run as Slurm jobs, not on the login node
BIOMERO_PULL_CPUS / _MEM        bound those pull jobs
BIOMERO_APPTAINER_TMPDIR        project-local Apptainer temp
BIOMERO_APPTAINER_CACHEDIR      project-local Apptainer cache
BIOMERO_SLURM_ZIP_CMD           unset; the default detects 7z or 7za
```

Do not reintroduce patches for these behaviors.

## Job Scripts Are Generated

`slurm_script_repo` is blank, so BIOMERO generates every job script from each
workflow's `descriptor.json` and uploads it. This repository ships no
workflow-specific `.sh` files, and converter images are built on Slurm rather
than pulled.

Keep it that way; local script copies and pinned converter images drift from
upstream. If an administrator sets a custom `slurm_script_repo`, that repository
is used as provided and is not mutated.

## Spider Policy

```text
SPIDER_USER
SPIDER_PROJECT
spider.surf.nl
/project/<project>/Share/biomero
```

`slurm_conversion_partition` is blank. CPU-only workflows, conversions, and
image-pull jobs omit `--partition` so Spider routes them to the normal default
partition.

`scripts/render-slurm-config.sh` renders `web/slurm-config-template.ini` into
`web/slurm-config.ini`, substituting `SPIDER_USER` and `SPIDER_PROJECT` and
setting mode 0666 because OMERO.biomero writes that file from `omeroweb` as
uid 999.

## GPU Policy

Per workflow in `slurm-config.ini`:

```text
<workflow>_use_gpu = True      marks a workflow GPU-native
<workflow>_job_<flag> = value  becomes --<flag>=value
```

There is no global partition or gres default: each GPU workflow names its own
in `slurm-config.ini`. A runtime `use_gpu` argument overrides the config value;
an explicit `device=cpu` or `use_gpu=false` receives no GPU params.

`BIOMERO_GPU_PARTITION` and `BIOMERO_GPU_GRES` were removed on 2026-09-17. They
only ever filled flags a workflow had not set, and both GPU workflows set both,
so they could never apply -- verified by comparing `make gpu` with the values
set, emptied and deleted. They were also a trap: a workflow setting only
`_job_gpus` inherited the global `--gres` and emitted both flags, which Spider
rejects. Without a global gres, either flag is fine; just never both on one
workflow.

Which GPU a workflow can use is a property of the workflow, not a policy to
centralise:

```text
deconvolve_plate    MIG-capable, but asks for 16 CPUs against a MIG node's 14
                    -> pinned to full A100
cellpose (classic)  reports torch.cuda.device_count() == 0 under MIG
                    -> pinned to full A100
stardist/stardist5d GPU-intended but not GPU-runnable as built; treat as CPU
CPU-only workflows  no partition at all, so Spider routes them to the default
```

`make gpu` prints the effective sbatch parameters per workflow without
submitting anything, and is the check that catches a `--gres`/`--gpus` conflict
before Spider does.

Set `_job_gres` or `_job_gpus` for a workflow, never both: upstream treats them
as mutually exclusive and Spider rejects `--gres` and `--gpus` together.

Check effective parameters without submitting:

```bash
docker compose exec -T biomeroworker /opt/omero/server/venv3/bin/python -c "
from biomero import SlurmClient
c = SlurmClient.from_config()
print(c.get_workflow_command('cellpose', 'latest', 'testdata', {})[0])"
```

## Spider GPU Resources

```text
gpu_a100_mig  gpu:a100_3g.20gb:4  wn-ga-[01-03]
gpu_a100_22c  gpu:a100:2          wn-gb-[01-05]
```

MIG node limits:

```text
MIG slices per node: 4
CPUs per MIG node: 14
RAM per MIG node: about 224 GiB
DefCpuPerGPU: 3
```

`*_job_mem` is system RAM, not VRAM. MIG VRAM comes from the GRES profile:
`gpu:a100_3g.20gb:1` is one CUDA device of about 20 GB, and `:2` is two separate
20 GB devices, not one 40 GB device.

CPU requests are node-level, not per slice. Requesting 2 MIGs does not double
the CPU count, and more than 14 CPUs on a MIG node is rejected.

CPU-only workflows should carry no GPU partition or GRES; requesting MIG GRES
reserves GPU capacity they cannot use.

## Per-Workflow GPU Assignment

```text
cellpose          full A100   classic container is not MIG-capable: reports
                              cuda True but device_count 0 under MIG
deconvolve_plate  full A100   runs on MIG, but 16 CPUs exceeds the MIG node limit
segmentation_cellpose4 MIG    torch 2.5.1 sees the MIG device and completes
stardist          CPU only    TF 1.15 container cannot register a GPU; the
stardist5d        CPU only    CUDA 10 / cuDNN 7 libraries are missing
fractal-cellpose-sam-biaflows, simple-zarr-plate-processor, cellexpansion,
cellexpansion_advanced, spotcounting, nuclei_measurements,
aggregates_measurements           CPU only as built
```

These follow from the pinned container versions, each already the latest
upstream release. Re-test with a probe before changing any of them:

```bash
sbatch --partition=gpu_a100_mig --gres=gpu:a100_3g.20gb:1 --cpus-per-task=3 \
  --mem=16G --time=00:05:00 --wrap="singularity exec --nv <sif> \
  python -c 'import torch;print(torch.cuda.is_available(),torch.cuda.device_count())'"
```

StarDist and Cellpose channel limitations are workflow-container behavior, not
Slurm integration behavior.

## Image Pulls and Apptainer

Pulls and builds are submitted to Slurm, not run on the login node, and use
project-local Apptainer temp and cache directories so Spider's small login
`/tmp` is not involved.

If image initialization looks successful but SIFs are missing:

```bash
ssh spider 'find /project/<project>/Share/biomero -name "pull_*-%j.log" -o -name "sing.log"'
```

Check for:

```text
failed <path> <version> exit=<code>
No space left on device
permission denied
```
