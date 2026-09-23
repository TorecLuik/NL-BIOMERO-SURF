# Standing Up a VM From Nothing

What breaks when the stack is deployed onto a machine that has never deployed
it, and the shape those failures share. Learned by rebuilding `biomeroqa` twice
from an empty volume on 2026-09-17/18; the narrative is in
`deployment_docs/fresh-vm-rebuild.md`, the fixes are on `prod-rebuild-2026-09`.

## The shape

Every one of these needs some piece of state to be *absent*, and on a host that
has deployed once, none of them are:

```text
.ssh/config, .ssh-worker/, omero/   an earlier deploy created them
built images                        compose prints no build progress
a populated volume                  Postgres starts in seconds, not minutes
a working .env                      its credentials already agree
Metabase content                    somebody built the dashboards by hand
```

So "it works when I redeploy" says nothing about a new VM. When asked whether
the deployment path works, the only answer that counts comes from an empty
volume and a fresh clone.

## Failures that only a bare VM reaches

Fixed, but worth recognising if they resurface:

- **A pipeline under `set -o pipefail` that reads a file which does not exist
  yet.** `grep X .env | tail -1 | cut -d= -f2-` fails the whole script when
  `.env` is absent. `|| true` at the end is the guard. This killed
  `make provision` before it printed its own report, leaving only
  `make: *** Error 2`.
- **Scraping a value out of a stream that also carries progress output.**
  `docker compose run ... id -g | tr -cd '0-9'` concatenated the digits of the
  run container's hex name onto the gid and produced a 600-digit "group".
  compose writes that progress to *stdout*, so `2>/dev/null` does not help.
  Take the last all-digits line.
- **A bind-mount source that nothing creates.** Docker makes a missing one
  `root:root`, and OMERO (uid 1000) then dies on
  `PermissionError: '/OMERO/certs'`. Postgres is not affected: its entrypoint
  chowns its own directory.
- **A readiness wait tuned to a warm start.** `initdb` on an empty volume takes
  longer than a restart against an existing cluster. Exhausting the loop must be
  an error, not a fall-through into the operation that needs it.
- **A preflight that cannot tell what the deploy reads from what it writes.**
  Requiring `.ssh/config` to pre-exist blocked every fresh VM on a file the
  deploy creates seconds later.

## Failures that leave the stack looking healthy

These matter most: ten containers up, all smoke tests green, and the thing
still does not work.

**The importer exits and nothing restarts it.** Every service is
`RestartPolicy: "no"`. When `biomero-importer` cannot log in to OMERO it retries
for five minutes, logs `Could not establish OMERO connection. Exiting.` and
stops. Imports queued from the UI are then accepted and silently never
collected. Its log is inside the container at `/auto-importer/logs/app.logs`,
*not* on stdout, so `docker compose logs` looks quiet.

```bash
sudo docker compose exec -T biomero-importer tail -40 /auto-importer/logs/app.logs
```

`OMERO_IMPORTER_USER` ships as `root`, so `OMERO_IMPORTER_PASSWORD` *is* root's
password and must equal `OMERO_ROOT_PASSWORD`. Preflight checks this now.

**A half-initialised importer database can never migrate itself.** If its first
start creates the tables and then dies, `alembic_version_omeroadi` is missing,
and every later start replays the migrations against a schema already at head:

```text
ProgrammingError: (psycopg2.errors.DuplicateColumn)
column "description" of relation "imports" already exists
```

`ADI_ALLOW_AUTO_STAMP=1` resolves it and is now the compose default.

**The Metabase dashboards do not exist.** Covered in
[metabase-dashboards.md](metabase-dashboards.md).

**`/logs` opens on a setup screen with every log already indexed.** Dashboards
answers and fluent-bit ships, but the index pattern is a saved object nothing
created, so the viewer shows none of it. `dashboards-init` creates it; see
[permissions-and-deployment.md](permissions-and-deployment.md).

These share a shape worth checking for directly: *responding and being usable
are different claims.* A smoke test that proves the first while reporting the
second is how a stack passes every check and still does not work.

## Judging "already done"

When making a step idempotent, decide what *complete* means before checking it.
Dashboard restore originally skipped anything present by name, which preserved a
0-tile shell from an interrupted run; then it counted tiles, which passed a
dashboard whose embedding had never been switched on -- and embedding is what
makes the iframe resolve. Check the property that makes the thing usable, not
the one that is easiest to count.

## Things that look broken and are not

- **Every Analyzer workflow card reads "Offline" for about a minute.** The
  status check queries Spider over SSH for each workflow's versions. Settled, it
  says `SLURM cluster is available. 11 workflows ready.` Hit
  `/omero_biomero/api/analyzer/slurm/status/` directly if unsure.
- **The importer image reports version `0.0.0`.** Upstream's Dockerfile tests
  `[ -d .git ]`, and in a submodule `.git` is a *file*. The submodule tag is the
  real version; `make doctor` judges by that.
- **`make provision` exits non-zero on a fresh VM.** It ends with a checklist of
  things it cannot do from inside the VM and exits 1 when any remain. Read the
  list rather than the exit code.

## Driving the UI by script

The BIOMERO panels are Blueprint.js. Tabs have stable ids
(`#bp5-tab-title_app-tabs_Admin`); trees expand by clicking
`.bp5-tree-node-caret`, not the label.

Two that cost real time:

- **The Importer enables file selection only after a destination is chosen.**
  Until then *Add to import list* stays disabled however many files are ticked.
- **`SLURM_Run_Workflow` options are HTML checkboxes.** Posting
  `Use_ZARR_Format=false` turns it **on** -- any value reads as checked, and only
  omitting the field leaves it off. That silently switches the run to Zarr
  passthrough, the conversion becomes a no-op, and the workflow dies on
  `IsADirectoryError: ... .ome.tiff.zarr` while every visible setting looks
  right.
