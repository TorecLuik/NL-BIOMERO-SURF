# Production Runbook

*Created 2026-09-23 · last updated 2026-09-23*

How the production deployment at
`https://surfbiomero.biomero-data-ch.src.surf-hosted.nl` is laid out, how to
operate it, and how to recover it. Written for whoever runs it next. How it was
built: [SETUP.md](../SETUP.md); why the storage is split this way:
[storage-architecture.md](storage-architecture.md).

## At a Glance

```text
VM         surfbiomero.biomero-data-ch.src.surf-hosted.nl   145.38.204.204
           SURF Research Cloud workspace, Ubuntu 22.04, CO rsc_co_202570
code       /opt/omero/NL-BIOMERO     branch prod-rebuild of
                                     github.com/slawa-loev/NL-BIOMERO
data       /data/surf-biomero-storage   500G attached volume
cluster    Spider, account SPIDER_USER in .env, project biomero
```

Admins are the members of the CO group `rsc_co_202570`. They are also in the
`docker` group, which is equivalent to root on this host.

## Where Things Live

| Path | What | Owner / mode |
| --- | --- | --- |
| `/opt/omero/NL-BIOMERO` | the git checkout | `rsc_co_202570`, setgid, group-writable |
| `…/.env` | every setting and secret; compose reads nothing else | `0640`, group `rsc_co_202570` |
| `…/.ssh/slurm_access_key` | cluster key registered on Spider | `0600`, the person who generated it |
| `…/web/biomero-config.json` | group → L-Drive folder mapping | tracked in git, edited for this VM |
| `…/deployment_docs/private/` | notes for the maintainers not for publication, e.g. a security report awaiting disclosure | gitignored, group-readable; exists only on this VM |
| `/data/surf-biomero-storage/database*` | the two Postgres 16 clusters | uid 999, `0700` |
| `…/omero` | OMERO binary repository | uid 1000 |
| `…/L-Drive` | user data; in-place imports link here | `0777`, set by `make deploy` |
| `…/config/volume-identity` | the database passwords this volume needs | `0600`, read through sudo |
| `…/backups/nightly` | nightly dumps, 14 days | root only |
| `…/backups/pre-upgrade-20260824` | snapshot of the previous deployment | root only |
| `…/backups/runtime-pre-rebuild-20260923` | the previous deployment's live data, as it was left on 2026-09-01 | root only |

Nothing under `/home` is part of the deployment. A personal account can be
removed without affecting it.

## Day-to-Day

```bash
cd /opt/omero/NL-BIOMERO
make ps                 # container status
make doctor             # configuration drift; changes nothing
make logs:omeroserver   # follow one service
make up / make down     # start / stop everything
make backup             # run the nightly backup now
```

Log search: `https://<host>/logs/`, user `biomero-logs`, password
`NGINX_LOGS_PASSWORD` in `.env`. Workflow and import dashboards are embedded in
OMERO.web; the Metabase admin is `METABASE_USER` in `.env`.

The workflow dashboard is filtered to the logged-in user and selected group,
so an admin who has run nothing (root, in `system`) sees empty workflow cards;
only the Slurm job cards are unfiltered. That is not missing data. To rebuild
the dashboards from `metabase/dashboards.json`:
`scripts/restore-metabase-dashboards.sh --force`, then `make up`.

## Boot and Shutdown

`nl-biomero.service` runs `make up` at boot once the volume is mounted, and
`make down` at shutdown. The containers themselves never restart on their own
(`RestartPolicy: "no"`): Docker starting them before the volume mounts would
make Postgres initialise an empty cluster on the root disk.

```bash
systemctl status nl-biomero.service
make install-services           # (re)install the units from .env
```

After pausing and resuming the workspace in the portal, check `make ps`: if the
volume was reattached after boot, run `sudo systemctl restart nl-biomero`.

## Backups

`nl-biomero-backup.timer` runs `scripts/backup-nightly.sh` at 02:30. Each run
writes `backups/nightly/<timestamp>/`: dumps of the OMERO, BIOMERO and Metabase
databases, the OMERO repository without caches, and `secrets.tar.gz` (`.env`,
`.ssh/`, `volume-identity`, the web configs). L-Drive is not copied.

```bash
systemctl list-timers nl-biomero-backup.timer
journalctl -u nl-biomero-backup.service -n 20
```

These backups sit on the same volume as the data. They cover a bad upgrade or a
deleted project, **not the loss of the volume**. See Open Items.

### Restoring a Database

Only the databases may be running: OMERO, the workers and Metabase hold
connections that a `--clean` restore would collide with.

```bash
make down
sudo docker compose up -d database database-biomero
B=/data/surf-biomero-storage/backups/nightly/<timestamp>
sudo cat $B/omero.pg_dump   | sudo docker compose exec -T database         pg_restore -U omero   -d omero   --clean --if-exists
sudo cat $B/biomero.pg_dump | sudo docker compose exec -T database-biomero pg_restore -U biomero -d biomero --clean --if-exists
make up
```

`sudo cat`, because the backup directory is root-only. Restore into a scratch
database first (`createdb`, then `pg_restore -d <scratch>`) when unsure which
timestamp to use.

## Rotating a Database Password

```bash
./scripts/volume-identity.sh rotate BIOMERO_POSTGRES_PASSWORD   # or POSTGRES_PASSWORD
make up
./scripts/restore-metabase-dashboards.sh   # Metabase keeps its own copy
```

It changes the password in the database, `.env` and `volume-identity` together,
and confirms over the network that the new one authenticates and the old one no
longer does. A `psql` from inside the database container proves nothing: its
local rules are `trust`.

## Rebuilding the VM

The volume holds all state, so a new workspace only needs the code, `.env` and
the cluster key:

1. Attach the volume to the new workspace, open ports 4063 and 4064.
2. `sudo git config --system http.version HTTP/1.1` so the clone works (see
   Known Issues; `make provision` sets it too, but the clone comes first).
3. Clone into `/opt/omero` as above, `make provision`.
4. Restore `.env` and `.ssh/` from the latest `secrets.tar.gz`.
5. `make init`, `make deploy`, `make install-services`.

`make deploy` takes the database passwords from `config/volume-identity` and
refuses to start if `.env` disagrees with the volume.

## Known Issues

**git over HTTPS fails with "could not read Username".** Ubuntu 22.04's libcurl
mishandles GitHub's HTTP/2 `103 Early Hints` responses and reports the
following `401` as an auth failure, even for public repositories.
`make provision` sets `git config --system http.version HTTP/1.1`; on a new VM,
set it by hand before the first clone.

**L-Drive is world-writable.** Several container users write to it, so
`make deploy` sets `0777`. Any account on the VM can modify user data; only CO
members have accounts.

**`web/biomero-config.json` is edited in the working tree.** It holds this
VM's group → folder mapping (Amsterdam, Leiden, Maastricht, Groningen), so
`git status` shows it modified. `git pull` keeps it unless upstream changes the
same file; then stash, pull, and reapply the `group_mappings` block.

**`.ssh/` belongs to whoever ran `make new-key`.** OpenSSH refuses a key that
anyone else can read, so it cannot be group-shared. A new owner either takes it
over (`sudo chown -R <user> .ssh`) or generates their own with
`make new-key FORCE=1`, which revokes the old registration.

## History

- **2026-07-02 → 2026-09-01** the first deployment ran on this volume, laid out
  under `runtime/`. It was upgraded on 2026-08-24 (snapshot in
  `backups/pre-upgrade-20260824`) and shut down cleanly on 2026-09-01 when its
  VM went away. No data was lost.
- **2026-09-23** rebuilt on this VM from `prod-rebuild`. The databases, OMERO
  repository and L-Drive were copied from `runtime/` into the current layout;
  users, groups, images and job history carried over. Metabase and the log
  indices were rebuilt rather than migrated. The BIOMERO database password was
  rotated and the cluster key replaced. Validated end to end afterwards: data,
  thumbnails, job history, dashboards, backup restore, reboot.

## Open Items

- **Off-VM backups.** Nothing leaves the volume yet. Pick a destination (SURF
  Research Drive, dCache, object storage) and copy `backups/nightly/` there.
