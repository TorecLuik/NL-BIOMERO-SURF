# NL-BIOMERO Deployment

*Created 2026-09-15 · last updated 2026-09-17*

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

## Storage

The stack's state does not live on the VM. Both databases, the OMERO image
repository, L-Drive and the secrets sit on an attached storage volume at
`$OMERO_DATA_PATH`, so they survive a workspace being rebuilt or replaced:

```text
$OMERO_DATA_PATH/
├── database/            OMERO Postgres
├── database-biomero/    BIOMERO Postgres
├── omero/               OMERO image repository
├── L-Drive/             user data, /data in the containers
├── config/              volume-identity
└── backups/             backup_master.sh output
```

`docker-compose.yml` declares no named volumes; every mount is a bind mount
under that path. The repository's `.env` and `.ssh/` are per-VM and gitignored, and
`web/slurm-config.ini` is rendered from the committed template, so a fresh clone
carries no secrets and nothing on the volume but `volume-identity` is
configuration.

Full detail, including how to set up a fresh VM and how to populate an empty
volume, is in [storage-architecture.md](storage-architecture.md).

## Observability

`opensearch-compose.yml` holds the log stack, started automatically by
`scripts/deploy-local-stack.sh` unless `START_LOG_STACK=0`:

```text
opensearch             log store, single node
opensearch-dashboards  log viewer, served under /logs
fluent-bit             tails ./logs and indexes into biomero-logs
opensearch-init        one-shot; installs the index template, then exits 0
```

Both compose files share one project name, derived from the directory, so
`docker compose ps` lists the log stack alongside the core services. But
`docker compose up -d` only starts what is in the files it was given, so running
it without `-f opensearch-compose.yml` leaves the log stack down while `ps` still
shows it. That is how it ends up stopped unnoticed. `make up` starts both.

```bash
make up                                          # or:
sudo docker compose -f opensearch-compose.yml up -d
curl -s localhost:9200/_cluster/health
curl -s 'localhost:9200/_cat/indices?v'
```

nginx proxies `/logs/` to port 5601 behind basic auth, reading
`/etc/nginx/.htpasswd` on the host. `make logs-auth` writes it from
`NGINX_LOGS_USER` and `NGINX_LOGS_PASSWORD` in `.env` and reloads nginx. It is
host state, so it does not survive rebuilding the VM; without it `/logs` answers
401 while the rest of the site works.

On startup Fluent Bit replays its backlog and OpenSearch answers some bulk
requests with HTTP 429. That is backpressure, not a fault, and it stops once the
backlog drains. A stalled pipeline looks different: the `biomero-logs` document
count stops rising. `scripts/bootstrap-prod.sh` checks exactly that.

`logs-compose.yml` is an unused alternative stack (Loki, Promtail, Grafana). No
script starts it. Use it only if replacing OpenSearch, and do not run both, since
both tail `./logs`.

No container sets a restart policy, so nothing comes back after a host reboot.
The same is true of the core services; bring the host back up with `make up` or
`scripts/bootstrap-prod.sh`.

## Versions

Pinned in `.env.example`, which `.env` overrides locally:

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

## Everyday Commands

A `Makefile` wraps the commands that get typed most. `make` on its own lists
them. Everything is a thin wrapper, so the underlying `docker compose` call
always works too.

```text
make provision             prepare a fresh VM: packages, submodule, nginx
make init                  fetch submodules, then run doctor
make deploy                set up, start and smoke test the stack
make doctor                diagnose drift, changes nothing
make set-host HOST=fqdn    set the per-VM public hostname
make docs-dates            refresh the date stamps in deployment_docs/
make reference-data        re-download and verify the test datasets
make up / down / ps        whole stack, log stack included
make build                 rebuild images and restart
make rebuild:SVC           rebuild one service
make restart:SVC           restart one service
make logs / logs:SVC       tail everything, or follow one service
make shell:SVC             shell in a container
make check / smoke         preflight, or full deploy and smoke test
make gpu                   effective Slurm params per workflow
make config                BIOMERO settings as the worker resolves them
make spider / snellius     ssh to a cluster from inside the worker
make psql / psql-biomero   psql into either database
```

`make` on its own lists them, and that listing is the one to trust: this table
goes stale, the help target cannot.

Service-scoped targets use a colon, not a slash: `logs/omeroweb` would collide
with the real `logs/` directory and make would treat it as already built.

Run `make gpu` after changing GPU configuration. It shows the parameters BIOMERO
will actually submit, which is where a `--gres` and `--gpus` conflict shows up
before Spider rejects the job.

## Rebuilding

```bash
make init      # fresh clone only: fetch the biomero-importer submodule
make set-host HOST=$(hostname -f)   # new host only
make deploy    # preflight, deploy, smoke test
make doctor    # diagnose without changing anything
```

For a brand-new VM, follow [new-vm.md](new-vm.md). It is two commands with one
manual stop: `make provision` prepares the host, then the secrets are restored
and ports 4063/4064 opened in SURF Research Cloud, then `make deploy`.

## Ports

```text
443    public      HTTPS; nginx proxies / to 4080, /metabase to 3000, /logs to 5601
4063   public      OMERO.insight
4064   public      OMERO.insight SSL
4080   localhost   OMERO.web, reached through nginx
3000   localhost   Metabase, reached through nginx
5601   localhost   OpenSearch Dashboards, reached through nginx
9200   localhost   OpenSearch API
```

There is no host firewall on this VM; 4063 and 4064 are opened in the SURF
Research Cloud interface. Everything else reaches users through nginx on 443.

The importer image builds from the `biomero-importer/` submodule, not from
`BIOMERO_IMPORTER_VERSION`, so a fresh clone must run `make init` first or the
build fails on an empty directory. Keep the submodule tag and the pin in step;
`make doctor` warns when they diverge.

The script checks prerequisites, deploys through `scripts/deploy-local-stack.sh`,
then smoke tests services, databases, the web login page, installed versions,
the runtime patch, and Spider reachability.

### Files that cannot be regenerated

```text
.env         deployment secrets; the only copy
.ssh/        Spider SSH key material
```

Archive both somewhere safe. `deploy-local-stack.sh` seeds `.env` from
`.env.example` when it is absent, which gives a stack that starts but has
placeholder credentials, so restore the real file when rebuilding a live
deployment. Everything else in the repo is reproducible from a clean checkout.

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

Global fallbacks in `.env.example`, applied only to flags a workflow has not set:

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

## Runtime Patches

Two patches, both idempotent and both failing loudly if upstream moves their
anchor. If one fails after a version bump, check whether upstream fixed the
behaviour itself and delete the patch rather than re-anchoring it.

`server/patch_biomero_scripts.py` guards an unchecked empty ID list in
`SLURM_Import_Results.py`. 2.8.2 reads the optional `ROI_Target_Image_IDs`
parameter and passes it straight to `getObjects("Image", ids=...)`; nothing
supplies it unless ROIs are requested, so an ordinary segmentation run sends
OMERO `where obj.id in ()` and every workflow fails at 90% with its results
already on disk. New in 2.8.2; the parameter does not exist in 2.7.0. See
[upstream-suggestions.md](upstream-suggestions.md) item 9.

The second is applied in both the worker and web images, because OMERO.biomero
submits analyzer jobs from the web process:

`biomeroworker/patch_biomero_runtime.py` injects
`biomeroworker/patches/generated_job_postprocess.py`, which appends
`set -eo pipefail` and `_nl_biomero_verify_outputs` to generated job scripts. A
workflow container can print a traceback, exit zero, and leave `data/out` empty;
without the check BIOMERO enters import and hangs around 90%.

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
uid 999. `make deploy` runs it every time, so an edit made through the admin UI
survives only until the next deploy -- a change worth keeping goes in the
template.

## Verifying a Change

Check the effective Slurm parameters without submitting anything:

```bash
docker compose exec -T biomeroworker /opt/omero/server/venv3/bin/python -c "
from biomero import SlurmClient
c = SlurmClient.from_config()
print(c.get_workflow_command('cellpose', 'latest', 'testdata', {})[0])"
```

Confirm no workflow emits `--gres` and `--gpus` together.
