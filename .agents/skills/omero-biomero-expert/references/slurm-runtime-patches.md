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
BIOMERO_GPUS
BIOMERO_GPU_GRES
BIOMERO_FORCE_GPU_WORKFLOWS
BIOMERO_FORCE_GPU_ALL_WORKFLOWS
```

For Spider, `slurm_conversion_partition` is intentionally blank. CPU-only workflows, conversions, and image-pull jobs should omit `--partition` so Spider routes them to the normal/default partition. Effective GPU jobs use explicit `slurm-config.ini`/UI workflow resources when present and fall back to env GPU defaults otherwise.
Per-workflow env overrides use the uppercased workflow key with non-alphanumeric characters replaced by underscores, for example `BIOMERO_GPU_PARTITION_CELLPOSE` or `BIOMERO_GPU_GRES_FRACTAL_CELLPOSE_SAM_BIAFLOWS`.
When a workflow is GPU-effective, GPU Slurm params are normalized so `--gres` and `--gpus` are never emitted together. Explicit UI/INI `*_job_partition`, `*_job_gres`, and `*_job_gpus` settings take precedence; env fills missing defaults and acts as a guardrail for known GPU-capable workflows that would otherwise run on CPU.

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

Effective GPU workflows are controlled by global defaults and optional per-workflow overrides:

```text
BIOMERO_FORCE_GPU_WORKFLOWS=cellpose,stardist,stardist5d,fractal-cellpose-sam-biaflows,deconvolve_plate
BIOMERO_GPU_PARTITION=gpu_a100_mig
BIOMERO_GPU_GRES=gpu:a100_3g.20gb:1
BIOMERO_GPUS=
BIOMERO_GPU_PARTITION_DECONVOLVE_PLATE=gpu_a100_22c
BIOMERO_GPU_GRES_DECONVOLVE_PLATE=none
BIOMERO_GPUS_DECONVOLVE_PLATE=1
BIOMERO_FORCE_GPU_ALL_WORKFLOWS=false
```

If a request explicitly sets device `cpu` or disables `use_gpu`, it should not receive GPU Slurm params. Otherwise GPU-native workflows default to `use_gpu=true`.
UI/INI workflow settings such as `cellpose_job_partition`, `cellpose_job_gres`, and `cellpose_job_gpus` take precedence when explicitly configured. If both GRES and GPUS are present, GRES wins because Spider rejects `--gres` and `--gpus` together. When no explicit UI/INI GPU resource is present, `BIOMERO_GPU_GRES...` is emitted as `--gres=...` instead of `--gpus=...`. Use `none`, `false`, or `off` on a workflow-specific `BIOMERO_GPU_GRES_<WORKFLOW_KEY>` to clear an inherited global GRES and fall back to that workflow's `BIOMERO_GPUS_<WORKFLOW_KEY>`. This keeps common GPU workflows on MIG while leaving heavier workflows, such as `deconvolve_plate`, on full A100.
Set `BIOMERO_FORCE_GPU_ALL_WORKFLOWS=true` only as an emergency/admin override to request the global GPU default for every workflow. It is useful when a workflow internally detects GPUs but has no `use_gpu` parameter; it is wasteful for CPU-only work and still respects explicit `device=cpu` or `use_gpu=false`.

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
