# BIOMERO Runtime Patch Retirement (2026-09)

This records which NL-BIOMERO runtime patches were retired when moving to
BIOMERO 2.8.2, what replaced them, and what deliberately stayed.

## How This Was Determined

All 13 `_replace_required` anchors in `biomeroworker/patch_biomero_runtime.py`
were extracted and tested against the real `slurm_client.py` shipped in each
BIOMERO wheel:

```text
biomero 2.5.3:   13 ok /  0 broken
biomero 2.8.2:    4 ok /  9 broken
biomero 2.9.0b7:  2 ok / 11 broken
```

The 9 breakages on 2.8.2 were not incidental refactoring. Upstream absorbed the
behavior as documented configuration keys, listed in
`docs/configuration-reference.rst` inside the 2.8.2 wheel.

## Retired Patches

| Retired patch | Upstream replacement | Set in |
| --- | --- | --- |
| `7z`/`7za` fallback | `slurm_zip_cmd` | upstream default already detects both |
| idempotent `mkdir -p` | none needed | upstream default |
| per-job env files | `env_file_submission` | `BIOMERO_ENV_FILE_SUBMISSION=true` |
| generated script sources env file | `env_file_submission` | same |
| conditional `singularity run --nv` | `inject_gpu_flag` | `BIOMERO_INJECT_GPU_FLAG=true` |
| per-workflow GPU sbatch params | `<workflow>_use_gpu`, `<workflow>_job_<flag>` | `slurm-config.ini` |
| required `slurm_data_bind_path` | upstream truthiness check | n/a |
| blank conversion partition | upstream truthiness check | `slurm_conversion_partition =` |
| pulls through Slurm, not login node | `slurm_image_pull_via_sbatch` | `BIOMERO_IMAGE_PULL_VIA_SBATCH=true` |
| bounded pull resources | `image_pull_cpus`, `image_pull_mem` | `BIOMERO_PULL_CPUS`, `BIOMERO_PULL_MEM` |
| project-local Apptainer temp/cache | `apptainer_tmpdir`, `apptainer_cachedir` | `BIOMERO_APPTAINER_TMPDIR`, `BIOMERO_APPTAINER_CACHEDIR` |

## Still Patched

Only output verification remains:

- Some workflow containers print a Python traceback, exit zero, and leave
  `data/out` empty. Without a check, BIOMERO proceeds into import and hangs
  around 90%. `biomeroworker/patches/generated_job_postprocess.py` appends
  `set -eo pipefail` and `_nl_biomero_verify_outputs` to descriptor-generated
  job scripts so the job fails immediately instead.

Upstream now emits the env-file loader and the `--nv` GPU flag itself, so those
parts were removed from the helper.

Retire this patch too once upstream verifies workflow outputs.

## GPU Policy Now Lives in slurm-config.ini

Upstream resolves GPU behavior per workflow:

```text
<workflow>_use_gpu = True        marks a workflow GPU-native
<workflow>_job_<flag> = value    becomes --<flag>=value
BIOMERO_GPU_PARTITION/GRES       fallbacks, only fill flags not already set
```

A runtime `use_gpu` argument still overrides the config value.

### Why full-A100 overrides use `_job_gres`, not `_job_gpus`

Upstream fills gaps by checking `--gres` and `--gpus` independently. A workflow
that sets only `_job_gpus` would still inherit the global MIG `--gres` and emit
both flags, which Spider rejects. Expressing the override as `_job_gres` keeps
it in the same slot as the global default, so exactly one GPU resource flag is
emitted.

This was caught by simulating the upstream parser over the rendered config
before building anything. Current result, 0 conflicts:

```text
cellpose           --partition=gpu_a100_22c  --gres=gpu:a100:1
deconvolve_plate   --partition=gpu_a100_22c  --gres=gpu:a100:1
all others         (none: Spider default partition)
```

GRES names were confirmed against `sinfo` on Spider:

```text
gpu_a100_22c  gpu:a100:2(S:0-43)              wn-gb-[01-05]
gpu_a100_mig  gpu:a100_3g.20gb:4(S:0-13)      wn-ga-[01-03]
```

### Per-workflow GPU decisions

- `cellpose` (classic): pinned to full A100. Not MIG-compatible; the container
  reports CUDA available but `torch.cuda.device_count()` is 0 under MIG.
- `deconvolve_plate`: pinned to full A100. Runs on MIG, but its 16 CPUs exceed
  the 14-CPU limit of a MIG node.
- `stardist`, `stardist5d`: left CPU-only. GPU-intended, but the current TF 1.15
  containers cannot register a GPU because CUDA 10 / cuDNN 7 libraries are
  missing. Set `<workflow>_use_gpu = True` once rebuilt.
- Everything else: CPU-only, so no `--partition` is sent and Spider routes the
  job to its normal default partition.

## Dependency Note

`biomero-importer` and `biomero[full]` pin incompatible ezomero versions
(3.2.3 vs 1.1.1), so the worker image installs them in two separate pip runs and
lets BIOMERO's pin win. This is safe because the importer only calls
`ezimport`, `get_group_id` and `post_map_annotation`, all present in 1.1.1, and
calls `ezimport` with keyword arguments. `pip check` reports the mismatch by
design; the previous known-good production image carried the same one.

Upstream aligns both on ezomero 3.2.3 in the 2.9 line. Revisit when adopting it.
