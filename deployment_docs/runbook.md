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
| `/data/surf-biomero-storage/database*` | the two Postgres 16 clusters | uid 999, `0700` |
| `…/omero` | OMERO binary repository | uid 1000 |
| `…/L-Drive` | user data; in-place imports link here | `0777`, set by `make deploy` |
| `…/config/volume-identity` | the database passwords this volume needs | `0640` |
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

```bash
make down
make up                                  # or start only database / database-biomero
B=/data/surf-biomero-storage/backups/nightly/<timestamp>
sudo docker compose exec -T database pg_restore -U omero -d omero --clean --if-exists < $B/omero.pg_dump
sudo docker compose exec -T database-biomero pg_restore -U biomero -d biomero --clean --if-exists < $B/biomero.pg_dump
make up
```

## Rebuilding the VM

The volume holds all state, so a new workspace only needs the code, `.env` and
the cluster key:

1. Attach the volume to the new workspace, open ports 4063 and 4064.
2. `sudo git config --system http.version HTTP/1.1` (see Known Issues).
3. Clone into `/opt/omero` as above, `make provision`.
4. Restore `.env` and `.ssh/` from the latest `secrets.tar.gz`.
5. `make init`, `make deploy`, `make install-services`.

`make deploy` takes the database passwords from `config/volume-identity` and
refuses to start if `.env` disagrees with the volume.

## Known Issues

**git over HTTPS fails with "could not read Username".** Ubuntu 22.04's libcurl
mishandles GitHub's HTTP/2 `103 Early Hints` responses and reports the
following `401` as an auth failure, even for public repositories. Fixed on this
host with `git config --system http.version HTTP/1.1`.

**L-Drive is world-writable.** Several container users write to it, so
`make deploy` sets `0777`. Any account on the VM can modify user data; only CO
members have accounts.

## History

- **2026-07-02 → 2026-09-01** the first deployment ran on this volume, laid out
  under `runtime/`. It was upgraded on 2026-08-24 (snapshot in
  `backups/pre-upgrade-20260824`) and shut down cleanly on 2026-09-01 when its
  VM went away. No data was lost.
- **2026-09-23** rebuilt on this VM from `prod-rebuild`. The databases, OMERO
  repository and L-Drive were copied from `runtime/` into the current layout;
  users, groups, images and job history carried over. Metabase and the log
  indices were rebuilt rather than migrated. The BIOMERO database password was
  rotated and the cluster key replaced.

## Open Items

- **Off-VM backups.** Nothing leaves the volume yet. Pick a destination (SURF
  Research Drive, dCache, object storage) and copy `backups/nightly/` there.
- **Cluster account.** `SPIDER_USER` is a personal account. Move to a project
  or service account before the original owner leaves, then `make new-key
  FORCE=1` and register the new key.
- **Ports 4063/4064** must be open in the portal for OMERO.insight.
