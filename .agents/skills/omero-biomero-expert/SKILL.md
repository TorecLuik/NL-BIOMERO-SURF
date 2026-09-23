---
name: omero-biomero-expert
description: OMERO/BIOMERO expert runbook for NL-BIOMERO deployments. Use for debugging and operating OMERO.server/web, OMERO.biomero, BIOMERO analyzer/importer/converter, Metabase dashboards, Docker Compose, Slurm/Spider, storage permissions, prod/dev SSH, runtime patches, logs, and Postgres verification.
---

# OMERO/BIOMERO Expert

Use this skill for NL-BIOMERO work on dev or prod. Prefer inspection over guesses: identify the active host, read the relevant compose/env/log state, verify data paths and permissions, then run a focused smoke test.

Never print secrets. Mask `.env`, container env, Metabase datasource JSON, passwords, secret keys, JWTs, and tokens in user-facing output.

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

Known paths:

```text
dev workspace: /home/sloev/local-share/opt/omero/NL-BIOMERO
prod stack:    /opt/omero/NL-BIOMERO
```

The checkout directory name matters: compose derives container and image names
from it, so do not assume the `nl-biomero-` prefix (see below).

There is currently no production VM. The `biomero-prod` host in `.ssh/config` points at a deleted machine and refuses connections; ignore it until a replacement is provisioned and the entry is repointed.

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

- [references/permissions-and-deployment.md](references/permissions-and-deployment.md): host/container UID/GID issues, ports and public reachability, per-VM hostname values, project-local SSH, writable bind mounts, `chmod`/ownership workarounds, production vs dev compose, the `/logs` viewer (basic-auth credentials, the index pattern, OpenSearch retention), disk space and runaway container logs, backup/restore guardrails.
- [references/metabase-dashboards.md](references/metabase-dashboards.md): BIOMERO Analyze/Import iframe failures, rebuilding both dashboards from `metabase/dashboards.json`, why the ids in `.env` are outputs rather than constants, Metabase's Postgres application database, datasource credential repair, signed embed smoke tests.
- [references/slurm-and-gpu.md](references/slurm-and-gpu.md): Spider/Slurm behavior, GPU and MIG policy, per-workflow GPU assignment, generated job scripts, image pulls and Apptainer, the output-verification patch.
- [references/workflow-runs.md](references/workflow-runs.md): tracing a workflow run by UUID, failures that name the wrong step, results that never reach OMERO, workflow input requirements (suffixes, channel counts, registered vs listed, ZARR), and images that look importable but are not.
- [references/importer-analyzer-storage.md](references/importer-analyzer-storage.md): BIOMERO.importer, analyzer-to-importer result flow, `/data` path invariants, `.analyzed`/`.processed`, shared storage, import order polling, importer logs.
- [references/fresh-vm.md](references/fresh-vm.md): deploying onto a machine that has never deployed this stack -- what only an empty volume reaches, failures that leave the stack looking healthy, and the UI gotchas when driving the panels by script.

Deployment configuration lives outside this skill, in `deployment_docs/deployment.md`: versions, GPU policy, the runtime patch, observability, and how to rebuild. `deployment_docs/new-vm.md` is the end-to-end checklist for standing up a fresh VM: `make provision` prepares the host, then the secrets are restored and ports 4063/4064 opened in SURF Research Cloud, then `make deploy`. Those three manual items cannot be done from inside the VM, and `scripts/provision-vm.sh` checks rather than assumes them. `deployment_docs/open-items.md` tracks what is still open on the current branch.
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
