# Slurm Runtime Patches

As of the 2026-09 rebuild (BIOMERO 2.8.2), almost all of the old runtime patches
are retired. Upstream BIOMERO now supports these behaviors as configuration.
See `setup_docs/patch_retirement_2026-09.md` for the full mapping.

Only one patch remains: `biomeroworker/patches/generated_job_postprocess.py`
appends `set -eo pipefail` and `_nl_biomero_verify_outputs` to
descriptor-generated job scripts, because upstream still lets a workflow exit
zero with an empty `data/out` and hang later during import.

The Metabase link patch in `web/` is also gone; OMERO.biomero 1.6.1 ships the
same localhost-rewrite behavior itself.

## Upstream Settings That Replaced Patches

```text
BIOMERO_INJECT_GPU_FLAG        conditional --nv and GPU sbatch resources
BIOMERO_GPU_PARTITION          fallback GPU partition
BIOMERO_GPU_GRES               fallback --gres
BIOMERO_ENV_FILE_SUBMISSION    per-job env files, sourced by generated scripts
BIOMERO_IMAGE_PULL_VIA_SBATCH  run image pulls as Slurm jobs
BIOMERO_PULL_CPUS/MEM          bound pull job resources
BIOMERO_APPTAINER_TMPDIR       project-local Apptainer temp
BIOMERO_APPTAINER_CACHEDIR     project-local Apptainer cache
BIOMERO_SLURM_ZIP_CMD          7z/7za selection (default auto-detects both)
```

GPU policy is per workflow in `slurm-config.ini`:

```text
<workflow>_use_gpu = True      mark a workflow GPU-native
<workflow>_job_<flag> = value  becomes --<flag>=value, wins over env fallbacks
```

Use `_job_gres` rather than `_job_gpus` for full-A100 overrides. Upstream fills
`--gres` and `--gpus` gaps independently, so a workflow setting only
`_job_gpus` still inherits the global MIG `--gres` and emits both flags, which
Spider rejects.

## Spider Policy

Spider/SURF-specific values are deployment policy, not generic BIOMERO defaults:

```text
SPIDER_USER
SPIDER_PROJECT
spider.surf.nl
/project/<project>/Share/biomero
BIOMERO_GPU_PARTITION
BIOMERO_GPU_GRES
```

For Spider, `slurm_conversion_partition` is intentionally blank. CPU-only workflows, conversions, and image-pull jobs should omit `--partition` so Spider routes them to the normal/default partition. Effective GPU jobs use explicit `slurm-config.ini`/UI workflow resources when present and fall back to env GPU defaults otherwise.
Per-workflow GPU policy lives in `slurm-config.ini` as `<workflow>_use_gpu` and `<workflow>_job_<flag>`. The old `BIOMERO_*_<WORKFLOW_KEY>` env overrides were retired with the runtime patch and are no longer read.
Explicit `<workflow>_job_*` settings take precedence; `BIOMERO_GPU_PARTITION` and `BIOMERO_GPU_GRES` are fallbacks that only fill flags a workflow has not already set.

## Runtime Patch File

`biomeroworker/patch_biomero_runtime.py` patches `biomero/slurm_client.py` inside the active container environment without importing BIOMERO during image build.

Reasons the patch exists:

- Support `7z` or `7za` on Slurm systems.
- Use `mkdir -p` so retry directories are idempotent.
- Require `slurm_data_bind_path` before submitting jobs; blank bind path can lead to Apptainer errors like `/ as sandbox is not authorized`.
- Write per-job env files because `sbatch` jobs may not inherit SSH session env.
- Normalize descriptor-generated scripts to source those env files.
- Replace hard-coded `singularity run --nv` with conditional GPU use.
- Add GPU partition/count/GRES only when effective `use_gpu` is true.
- Fail generated jobs when output directories are missing or empty.
- Run image pulls/builds through Slurm, not the login node, with project-local Apptainer temp/cache.
- Bound image pull resources using `BIOMERO_PULL_CPUS` and `BIOMERO_PULL_MEM`.

Remove the patch only when upstream BIOMERO includes equivalent behavior.

## Generated Job Script Normalization

`biomeroworker/patches/generated_job_postprocess.py` injects:

- `set -eo pipefail`
- optional sourcing of `BIOMERO_ENV_FILE`
- conditional `GPU_FLAG="--nv"` based on `USE_GPU`
- `_nl_biomero_verify_outputs`

`biomeroworker/patches/jobs/biomero_job_helpers.sh` defines `nl_biomero_verify_outputs`, which fails if `$DATA_PATH/data/out` does not exist or is empty. This prevents workflows that print tracebacks but exit zero from hanging later during import.

## Slurm Config Rendering

`scripts/render-slurm-config.sh` renders:

```text
web/slurm-config-template.ini -> web/slurm-config.ini
```

It substitutes `SPIDER_USER` and `SPIDER_PROJECT`, then sets `web/slurm-config.ini` mode `0666` because OMERO.biomero writes this bind-mounted file from `omeroweb` as uid 999.

`web/slurm-config-template.ini` and `web/slurm-config.ini` include comments documenting GPU policy: GPU resources are intentionally not static in the workflow definitions; the runtime patch injects them only for effective GPU jobs.

## Image Pulls and Apptainer

Image initialization should not run parallel background pulls on the login node. The patch submits pull jobs via Slurm, creates project-local `.apptainer_tmp` and `.apptainer_cache`, and emits real failures.

If image initialization appears successful but SIFs are missing:

```bash
ssh spider 'find /project/<project>/Share/biomero -name "pull_*-%j.log" -o -name "sing.log"'
```

Check for:

```text
failed <path> <version> exit=<code>
No space left on device
permission denied
```

## GPU Behavior

GPU-native workflows are marked per workflow in `slurm-config.ini`; the env vars are global fallbacks only:

```text
slurm-config.ini
  cellpose_use_gpu = True
  cellpose_job_partition = gpu_a100_22c
  cellpose_job_gres = gpu:a100:1
  deconvolve_plate_use_gpu = True
  deconvolve_plate_job_partition = gpu_a100_22c
  deconvolve_plate_job_gres = gpu:a100:1

.env / .env.shared
  BIOMERO_INJECT_GPU_FLAG=true
  BIOMERO_GPU_PARTITION=gpu_a100_mig
  BIOMERO_GPU_GRES=gpu:a100_3g.20gb:1
```

If a request explicitly sets device `cpu` or passes `use_gpu=false`, it does not receive GPU Slurm params. Otherwise the workflow's `<workflow>_use_gpu` value decides.

Use `_job_gres` rather than `_job_gpus` for full-A100 overrides. Upstream fills `--gres` and `--gpus` gaps independently, so a workflow that sets only `_job_gpus` still inherits the global MIG `--gres` and emits both flags, which Spider rejects.

Verify the effective parameters without submitting anything:

```bash
docker compose exec -T biomeroworker /opt/omero/server/venv3/bin/python -c "
from biomero import SlurmClient
c = SlurmClient.from_config()
print(c.get_workflow_command('cellpose', 'latest', 'testdata', {})[0])"
```

## Spider MIG Resources

Current Spider A100 MIG capacity, verified on 2026-06-24:

```text
gpu_a100_mig  | gpu:a100_3g.20gb:4 | wn-ga-[01-03]
gpu_a100_22c  | gpu:a100:2         | wn-gb-[01-05]
```

MIG node limits:

```text
MIG slices per node: 4
CPUs per MIG node: 14
RAM per MIG node: about 224 GiB
Slurm default CPU per GPU/MIG: DefCpuPerGPU=3
```

Use `*_job_gres` for MIG, not `*_job_gpus`:

```ini
workflow_job_partition = gpu_a100_mig
workflow_job_gres = gpu:a100_3g.20gb:1
workflow_job_cpus-per-task = 3
```

Do not configure both `*_job_gres` and `*_job_gpus` for the same workflow. Spider rejects mixed `--gres` and `--gpus`; the runtime patch normalizes this, and explicit GRES wins.

`*_job_mem` is system RAM, not VRAM. MIG VRAM comes from the GRES profile. `gpu:a100_3g.20gb:1` gives one CUDA device with about 20 GB VRAM. `gpu:a100_3g.20gb:2` gives two separate about-20 GB CUDA devices, not one combined 40 GB device.

CPU requests are node-level, not per MIG slice:

```text
1 MIG: normal 3-4 CPUs, practical max 14 CPUs
2 MIGs: normal 6-8 CPUs, practical max 14 CPUs
3 MIGs: normal about 9 CPUs, practical max 14 CPUs
4 MIGs: normal 12 CPUs, practical max 14 CPUs
```

Observed scheduler behavior:

```text
--gres=gpu:a100_3g.20gb:4 --cpus-per-task=16  -> rejected
--gres=gpu:a100_3g.20gb:4 --cpus-per-task=14  -> accepted
--gres=gpu:a100_3g.20gb:2 --cpus-per-task=8   -> completed; allocation had cpu=9, gres/gpu=2
```

Requesting 2 MIGs does not double the requested CPU count. Do not assume 8 CPUs plus 2 MIGs becomes 16 CPUs.

CPU-only workflows can be scheduled on MIG nodes, but if they request `gpu:a100_3g.20gb:N` they reserve GPU capacity while using only CPU. Prefer leaving CPU-only workflows without a GPU partition/GRES unless intentionally using MIG nodes for spare CPU capacity.

## Workflow GPU/MIG Compatibility

Compatibility checks from source inspection and Slurm smoke tests on 2026-06-24:

| Workflow | Type | Generally GPU runnable | MIG compatible | Operational implication |
| --- | --- | --- | --- | --- |
| `deconvolve_plate` | GPU | Yes | Yes | Runs on MIG correctly. Real BIOMERO/Slurm jobs completed on `gpu:a100_3g.20gb:1` and `:2`. |
| `segmentation_cellpose4` | GPU | Yes | Yes | Runs on MIG. Torch 2.5.1 sees `NVIDIA A100-PCIE-40GB MIG 3g.20gb`; Cellpose4 CLI completed on one MIG and wrote masks. |
| `cellpose` classic | GPU | Yes, full GPU only | No | Classic container is not MIG-compatible: Torch reports CUDA but `torch.cuda.device_count()` is 0 under MIG. Keep on full A100 if GPU is needed. |
| `stardist` | GPU-intended | No, current container | No | Current container does not use GPU on MIG or full A100. TF 1.15 sees `libcuda`/A100 but cannot register GPU because CUDA 10/cuDNN 7 libraries are missing. Treat as CPU-only until rebuilt. |
| `stardist5d` | GPU-intended | No, current container | No | Same as `stardist`; TF1 stack cannot load required CUDA 10/cuDNN 7 libs. Treat as CPU-only until rebuilt. |
| `fractal-cellpose-sam-biaflows` | CPU-only as built | No | Yes, CPU-only | Can run on MIG nodes as CPU work, but requesting MIG GRES wastes GPU. Prefer CPU/default partition. |
| `simple-zarr-plate-processor` | CPU-only | No | Yes, CPU-only | Can run on MIG nodes as CPU work, but requesting MIG GRES wastes GPU. Prefer CPU/default partition. |
| `cellexpansion` | CPU-only | No | Yes, CPU-only | Can run on MIG nodes as CPU work, but requesting MIG GRES wastes GPU. Prefer CPU/default partition. |
| `cellexpansion_advanced` | CPU-only | No | Yes, CPU-only | Can run on MIG nodes as CPU work, but requesting MIG GRES wastes GPU. Prefer CPU/default partition. |
| `spotcounting` | CPU-only | No | Yes, CPU-only | Can run on MIG nodes as CPU work, but requesting MIG GRES wastes GPU. Prefer CPU/default partition. |
| `nuclei_measurements` | CPU-only | No | Yes, CPU-only | Can run on MIG nodes as CPU work, but requesting MIG GRES wastes GPU. Prefer CPU/default partition. |
| `aggregates_measurements` | CPU-only | No | Yes, CPU-only | Can run on MIG nodes as CPU work, but requesting MIG GRES wastes GPU. Prefer CPU/default partition. |

Known test results:

```text
deconvolve_plate, 2 MIGs:
  Slurm job 36943688, COMPLETED, gpu_a100_mig, gres/gpu=2, cpu=9, mem=64G

deconvolve_plate, 1 MIG:
  Slurm job 36944263, COMPLETED, gpu_a100_mig, gres/gpu=1, cpu=9, mem=64G

classic cellpose on MIG:
  Slurm job 36944301, FAILED
  RuntimeError: torch.cuda.device_count() is 0 under MIG

segmentation_cellpose4 on MIG:
  Slurm job 36944593, COMPLETED framework probe
  torch 2.5.1, cuda_available=True, device_count=1
  device_name=NVIDIA A100-PCIE-40GB MIG 3g.20gb
  Slurm job 36944617, COMPLETED Cellpose4 CLI smoke test
  log: TORCH CUDA version installed and working; using GPU (CUDA)
  output: synthetic_cp_masks.tif

stardist on full A100:
  Slurm job 36944563, FAILED probe
  TensorFlow 1.15.0 cannot load libcudart.so.10.0, libcublas.so.10.0,
  libcufft.so.10.0, libcurand.so.10.0, libcusolver.so.10.0,
  libcusparse.so.10.0, libcudnn.so.7
  tf_cuda_gpu_available=False

stardist5d on full A100:
  Slurm job 36944564, FAILED probe
  Same missing CUDA 10/cuDNN 7 libraries as stardist
  tf_cuda_gpu_available=False
```

Recommended settings after these tests:

```ini
# Good MIG candidate
deconvolve_plate_job_partition = gpu_a100_mig
deconvolve_plate_job_gres = gpu:a100_3g.20gb:1
deconvolve_plate_job_cpus-per-task = 4
deconvolve_plate_job_mem = 64GB

# Good MIG candidate
segmentation_cellpose4_job_partition = gpu_a100_mig
segmentation_cellpose4_job_gres = gpu:a100_3g.20gb:1
segmentation_cellpose4_job_cpus-per-task = 4
segmentation_cellpose4_job_mem = 16GB

# Classic Cellpose should remain full GPU if GPU is needed
cellpose_job_partition = gpu_a100_22c
cellpose_job_gpus = 1
cellpose_job_cpus-per-task = 8
cellpose_job_mem = 16GB
```

Do not put `stardist`/`stardist5d` on full GPU merely because they are GPU-intended. Their current containers do not use full A100 either; rebuild with a matching CUDA/cuDNN stack or treat them as CPU-only.

## Output Verification

Workflow result import should fail early if no outputs exist. Look for error text:

```text
ERROR: Workflow output directory does not exist
ERROR: Workflow completed without producing files
```

These are more actionable than a later BIOMERO UI hang at 90%.

## Script Repository Contract

When `slurm_script_repo` is empty, BIOMERO generates scripts locally and NL-BIOMERO normalizes them. If an administrator supplies a custom Git repository, that repository is used as provided; do not silently mutate custom repository contracts.

## Setup Audit Notes

`setup_docs/slurm_spider_patch_audit.md` distinguishes generally useful Slurm improvements from Spider-specific policy. `setup_docs/stack_patch_audit.md` records patch intent and cleanup candidates. Consult both before removing patches or converting them into upstream PRs.
