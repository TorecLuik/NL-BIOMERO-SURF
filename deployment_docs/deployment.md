# NL-BIOMERO Deployment

*Created 2026-09-15 · last updated 2026-09-23*

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
└── backups/             nightly/: scripts/backup-nightly.sh
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
dashboards-init        one-shot; creates the /logs index pattern, then exits 0
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

No container sets a restart policy: Docker starting Postgres before the volume
mounts would initialise an empty cluster on the boot disk. On production,
`nl-biomero.service` (`make install-services`) starts the stack at boot once the
volume is mounted; elsewhere, `make up` after a reboot.

## Versions

The component versions are pinned in `.env.example`, which `.env` overrides
locally; the OMERO base images are pinned in `server/Dockerfile` and
`web/Dockerfile`. `make doctor` compares what is installed against the pins.

`BIOMERO_VERSION` has no `v` prefix; it is passed straight to pip.

## Everyday Commands

A `Makefile` wraps the commands that get typed most; `make` on its own lists
them. Everything is a thin wrapper, so the underlying `docker compose` call
always works too.

Service-scoped targets use a colon, not a slash: `logs/omeroweb` would collide
with the real `logs/` directory and make would treat it as already built.

Run `make gpu` after changing GPU configuration. It shows the parameters BIOMERO
will actually submit, which is where a `--gres` and `--gpus` conflict shows up
before Spider rejects the job.

## Rebuilding

```bash
make init      # submodule, rendered config, hostname, /logs auth, doctor
make deploy    # preflight, deploy, smoke test
make doctor    # diagnose without changing anything
```

For a brand-new VM, follow [new-vm.md](new-vm.md).

The importer image builds from the `biomero-importer/` submodule, not from
`BIOMERO_IMPORTER_VERSION`, so a fresh clone must run `make init` first or the
build fails on an empty directory. Keep the submodule tag and the pin in step;
`make doctor` warns when they diverge.

`make deploy` runs `scripts/bootstrap-prod.sh`: it checks prerequisites, deploys
through `scripts/deploy-local-stack.sh`, then smoke tests services, databases,
the web login page, installed versions, the runtime patches, Spider
reachability, the log stack and the public URL.

## Ports

```text
443    public      HTTPS; nginx proxies / to 4080, /metabase to 3000, /logs to 5601
4063   public      OMERO.insight
4064   public      OMERO.insight SSL
4080   loopback    OMERO.web, reached through nginx
3000   loopback    Metabase, reached through nginx
5601   loopback    OpenSearch Dashboards, reached through nginx
9200   loopback    OpenSearch API, unauthenticated
9300   loopback    OpenSearch transport, unused on a single node
9600   loopback    OpenSearch Performance Analyzer
```

The compose files bind every backend port to `127.0.0.1`, so they are not
reachable from outside the host whatever the network rules say. There is no host
firewall; 4063 and 4064 are opened in the SURF Research Cloud interface, and
everything else reaches users through nginx on 443. Reach a backend port from
your own machine with an SSH tunnel, e.g. `ssh -L 5601:localhost:5601 <host>`.

The importer image builds from the `biomero-importer/` submodule, not from
`BIOMERO_IMPORTER_VERSION`, so a fresh clone must run `make init` first or the
build fails on an empty directory. Keep the submodule tag and the pin in step;
`make doctor` warns when they diverge.

### Files that cannot be regenerated

```text
.env         deployment secrets
.ssh/        Spider SSH key material
```

`scripts/backup-nightly.sh` copies both into `secrets.tar.gz` on the volume;
keep a copy off the VM as well. Everything else in the repo is reproducible
from a clean checkout.

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

`BIOMERO_INJECT_GPU_FLAG=true` in `.env` is what makes BIOMERO emit `--nv` and
GPU sbatch resources at all, and only for workflows whose `use_gpu` is true.

There is no global partition or gres default. Each GPU workflow names its own,
next to the reason it needs that one, because the right answer differs per
workflow: `deconvolve_plate` runs on MIG but asks for 16 CPUs, more than a MIG
node's 14, and classic cellpose reports `torch.cuda.device_count() == 0` under
MIG. A single default would be wrong for one of them either way.

Set `_job_gres` or `_job_gpus`, never both for one workflow: upstream treats
them as mutually exclusive and Spider rejects `--gres` and `--gpus` together.

CPU-only workflows carry no `use_gpu` and no partition, so Spider routes them to
its normal default partition.

### Spider GPU resources

```text
gpu_a100_mig  gres gpu:a100_3g.20gb   MIG slices; 14 CPUs per node
gpu_a100_22c  gres gpu:a100           full A100
```

Node counts and slice counts are Spider's to change; check them with
`sinfo -p gpu_a100_mig,gpu_a100_22c -o '%P %G %c %D'`.

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

These follow from the pinned container versions. Re-test with a probe job
before changing any of them, and after bumping a workflow's version:

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
already on disk. Delete the patch on moving to BIOMERO 2.9, which guards the
empty list itself. See [upstream-suggestions.md](upstream-suggestions.md)
item 7.

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

The worker and web read only that rendered file: `BIOMERO_SLURM_CONFIG_FILE`
puts BIOMERO in authoritative-file mode, so its default search path -- which
starts with upstream's local-dev `/etc/slurm-config.ini`, still baked into the
worker image -- is never consulted.

`scripts/render-slurm-config.sh` renders `web/slurm-config-template.ini` into
`web/slurm-config.ini`, substituting `SPIDER_USER` and `SPIDER_PROJECT` and
setting mode 0666 because OMERO.biomero writes that file from `omeroweb` as
uid 999. `make deploy` runs it every time, so an edit made through the admin UI
survives only until the next deploy -- a change worth keeping goes in the
template.

## Metabase Dashboards

OMERO.web embeds two dashboards, named in `.env` by
`METABASE_WORKFLOWS_DB_PAGE_DASHBOARD_ID` and
`METABASE_IMPORTS_DB_PAGE_DASHBOARD_ID`. Their definitions are committed in
`metabase/dashboards.json`, and `make deploy` rebuilds them through
`scripts/restore-metabase-dashboards.sh`, writing the ids it used back into
`.env`. Everything per-install -- databases, tables, fields, filter targets --
travels by name, so the file carries no ids and no passwords.

To change a dashboard, edit it in Metabase, then export and commit:

```bash
make export-metabase-dashboards          # the two dashboards .env embeds
make export-metabase-dashboards IDS=5    # or an explicit set
```

The round trip is what keeps the file honest; editing it by hand is possible
but unchecked.

## Verifying a Change

Check the effective Slurm parameters without submitting anything:

```bash
docker compose exec -T biomeroworker /opt/omero/server/venv3/bin/python -c "
from biomero import SlurmClient
c = SlurmClient.from_config()
print(c.get_workflow_command('cellpose', 'latest', 'testdata', {})[0])"
```

Confirm no workflow emits `--gres` and `--gpus` together.
