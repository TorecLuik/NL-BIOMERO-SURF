---
name: omero-biomero-expert
description: OMERO/BIOMERO expert runbook for NL-BIOMERO deployments. Use for debugging and operating OMERO.server/web, OMERO.biomero, BIOMERO analyzer/importer/converter, Metabase dashboards, Docker Compose, Slurm/Spider, storage permissions, prod/dev SSH, runtime patches, logs, and Postgres verification.
---

# OMERO/BIOMERO Expert

Use this skill for NL-BIOMERO work on dev or prod. Prefer inspection over guesses: identify the active host, read the relevant compose/env/log state, verify data paths and permissions, then run a focused smoke test.

Never print secrets. Mask `.env`, container env, Metabase datasource JSON, passwords, secret keys, JWTs, and tokens in user-facing output.

**Production is live and has users.** Before anything that restarts, rebuilds
or redeploys it (`make deploy`, `make build`, `make up` after a config change,
`systemctl restart nl-biomero`), check that no workflow or import is running
(below) and ask the operator. Read-only inspection needs no permission.

```bash
# unfinished tasks in the last hours, and Spider jobs still queued or running
sudo docker compose exec -T database-biomero psql -U biomero -d biomero -Atc \
  "SELECT task_name, start_time FROM biomero_task_execution
   WHERE end_time IS NULL AND start_time > now() - interval '6 hours'"
sudo docker compose exec -T biomeroworker ssh spider 'squeue -u $USER -h'
```

Claims about a password, a process or a file need a probe that can fail: read
[references/verification-pitfalls.md](references/verification-pitfalls.md)
before trusting one.

## First Checks

Start with the Makefile. `make` lists every target; these three answer most questions before any manual inspection:

```bash
make ps       # all containers, log stack included
make doctor   # read-only: submodule, pin and image drift
make config   # BIOMERO settings as the worker resolves them
```

`make doctor` is the fastest way to find the failure modes this deployment actually hits: a stale `biomero-importer` submodule, `.env` and `.env.example` disagreeing on pins, or an image that does not match the pin it was supposedly built from.

Two repair targets run from `make deploy` and are safe to re-run alone, before
reaching for manual fixes:

```bash
make metabase-dashboards   # rebuild the embedded dashboards from the repository
make logs-retention        # apply the OpenSearch retention policy, clear audit indices
```

Hosts:

```text
prod  surfbiomero.biomero-data-ch.src.surf-hosted.nl  145.38.204.204
      stack /opt/omero/NL-BIOMERO           data /data/surf-biomero-storage
qa    biomeroqa.sda-development.src.surf-hosted.nl    145.38.189.61
      stack /local-share/biomero-snellius-surf  data /data/biomero-data
      a test box built from an empty volume; may be paused
dev   biomerotest.sda-development.src.surf-hosted.nl
      checkout /local-share/biomero-snellius-surf, where changes are made,
      committed and pushed; prod and qa pull them
```

Each is reached with plain `ssh <address>` from biomerotest. Prod's operator
runbook is `deployment_docs/runbook.md`.

The checkout directory name matters: compose derives container and image names
from it, so do not assume the `nl-biomero-` prefix (see below).

Docker requires `sudo` here. If `docker ps` fails on `/var/run/docker.sock`, retry with `sudo docker ...`; every `make` target already does.

Core service names:

```text
omeroweb  omeroserver  biomeroworker  omeroworker-1
biomero-importer  database  database-biomero  metabase
```

**Address services through compose, not by container name.** Compose derives
container names from the *project directory*, so the same stack is
`nl-biomero-omeroweb-1` in one checkout and
`biomero-snellius-surf-omeroweb-1` in another. Hardcoding the `nl-biomero-`
form is a bug this repository has already shipped three times: `make doctor`
reported "importer image not built yet" and "cannot read the metabase
database", and `make reference-data` reported "biomeroworker is not running",
all while everything was running fine. A lookup that cannot find its target
must say so as a lookup failure, never as a fact about the deployment.

```bash
sudo docker compose exec -T biomeroworker <cmd>     # not docker exec <name>
sudo docker compose ps --status running --format '{{.Service}}'
sudo docker compose config --images                 # image names, also derived
```

`metabase` is the exception: it sets `container_name: metabase` explicitly.

Quick status:

```bash
cd /opt/omero/NL-BIOMERO
sudo docker compose ps
sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
sudo docker compose logs --tail=120 metabase omeroweb biomero-importer
```

## Reference Routing

Read only the relevant reference before acting:

- [references/permissions-and-deployment.md](references/permissions-and-deployment.md): the credentials the data depends on (`volume-identity`: fill, adopt, rotate), boot and restart, nightly backup and restore, host/container UID/GID issues, ports and public reachability, per-VM hostname values, project-local SSH, writable bind mounts, `chmod`/ownership workarounds, production vs dev compose, the `/logs` viewer (basic-auth credentials, the index pattern, OpenSearch retention), disk space and runaway container logs, backup/restore guardrails.
- [references/metabase-dashboards.md](references/metabase-dashboards.md): BIOMERO Analyze/Import iframe failures, rebuilding both dashboards from `metabase/dashboards.json`, why the ids in `.env` are outputs rather than constants, Metabase's Postgres application database, datasource credential repair, signed embed smoke tests.
- [references/slurm-and-gpu.md](references/slurm-and-gpu.md): Spider/Slurm behavior, GPU and MIG policy, per-workflow GPU assignment, generated job scripts, image pulls and Apptainer, the output-verification patch.
- [references/workflow-runs.md](references/workflow-runs.md): tracing a workflow run by UUID, failures that name the wrong step, results that never reach OMERO, workflow input requirements (suffixes, channel counts, registered vs listed, ZARR), and images that look importable but are not.
- [references/importer-analyzer-storage.md](references/importer-analyzer-storage.md): BIOMERO.importer, analyzer-to-importer result flow, `/data` path invariants, `.analyzed`/`.processed`, shared storage, import order polling, importer logs.
- [references/fresh-vm.md](references/fresh-vm.md): deploying onto a machine that has never deployed this stack -- what only an empty volume reaches, failures that leave the stack looking healthy, and the UI gotchas when driving the panels by script.
- [references/verification-pitfalls.md](references/verification-pitfalls.md): probes on this stack that succeed whatever the truth is -- passwords checked from inside Postgres, `omero login` session reuse, `pgrep` matching itself, root-only directories -- and the negative control that catches them.

Deployment configuration lives outside this skill, in `deployment_docs/deployment.md`: versions, GPU policy, the runtime patch, observability, and how to rebuild. `deployment_docs/new-vm.md` is the end-to-end checklist for standing up a fresh VM: `make provision` prepares the host, then the secrets are restored and ports 4063/4064 opened in SURF Research Cloud, then `make deploy`. Those three manual items cannot be done from inside the VM, and `scripts/provision-vm.sh` checks rather than assumes them. `deployment_docs/runbook.md` covers operating the production VM and lists what is still open.
`deployment_docs/pipeline-tests.md` is the browser-driven end-to-end test suite
and records which checks have passed; `deployment_docs/upstream-suggestions.md`
collects behaviour that cannot be fixed in this repo.

## Converter and Importer Code

The `biomero-importer` runs `biomero-converter` with rootless Podman inside the importer container. The importer container's internal Podman store is ephemeral when the container is recreated, so reload rebuilt converter images after rebuilds or importer recreation.

```bash
docker build -t cellularimagingcf/biomero-converter:latest .
docker save cellularimagingcf/biomero-converter:latest \
  | sudo docker compose exec -T biomero-importer podman load
```

If importer Python code changes, mounted source may update immediately but worker processes can cache modules. Restart the service:

```bash
docker compose restart biomero-importer
```

## Importer Logs and Test Images

Importer logs:

```text
<stack-root>/logs/biomero-importer/app.logs
<stack-root>/logs/biomero-importer/cli.<UUID>*.errs
```

Sample test images:

```text
biomero-importer/tests/Barbie1.tif
biomero-importer/tests/Barbie2.tif
biomero-importer/tests/Barbie3.tif
```

Common in-container paths:

```text
/auto-importer/tests/Barbie1.tif
/auto-importer/tests/Barbie2.tif
/auto-importer/tests/Barbie3.tif
```

## OMERO Database Verification

Use Postgres for high-confidence import verification:

```bash
make psql    # or: sudo docker compose exec -T database psql -U omero -d omero
```

Useful checks:

```sql
SELECT id, plate, name FROM plateacquisition WHERE plate = <PLATE_ID>;

SELECT ws.id AS wellsample_id, ws.well, ws.image
FROM wellsample ws
JOIN well w ON ws.well = w.id
WHERE w.plate = <PLATE_ID>;

SELECT id, thez, thec, thet, deltat
FROM planeinfo
WHERE pixels IN (SELECT id FROM pixels WHERE image = <IMAGE_ID>)
ORDER BY thet;
```

For Incucyte imports, redundant `plateacquisition` rows usually indicate the double-timepoint-folder UI problem. `planeinfo.deltat` should contain meaningful increments, not all zero.

## OMERO Physical Units

When updating registration code such as `biomero-importer/biomero_importer/utils/register.py`, do not wrap raw values in gateway helpers when instantiating physical unit model classes.

Correct:

```python
from omero.model import TimeI
from omero.model.enums import UnitsTime
p_info.deltaT = TimeI(d_t, UnitsTime.SECOND)
```

Incorrect:

```python
p_info.deltaT = TimeI(rdouble(d_t), UnitsTime.SECOND)
```
