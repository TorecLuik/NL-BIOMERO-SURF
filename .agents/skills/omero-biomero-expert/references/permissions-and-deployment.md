# Permissions and Deployment

## Mental Model

NL-BIOMERO mixes host files, Docker volumes, and containers running as different users. Many failures that look like BIOMERO bugs are actually write-access or path-identity problems.

High-risk write paths:

```text
web/L-Drive                 # mounted as /data in server, worker, web, importer
logs/*                      # mounted into service-specific log paths
web/slurm-config.ini        # written by OMERO.biomero admin UI from omeroweb
web/biomero-config.json     # written/read by OMERO.biomero and worker
web/group-mappings.json     # dev/newer OMERO.biomero group mapping file
metabase/                   # H2 app DB, owned by metabase uid/gid 2000
.ssh/                       # project-local copy mounted into biomeroworker
```

Observed runtime UIDs:

```text
omero-web / omero-server often write as uid 999
biomero-importer runs as OMERO_CONTAINER_USER and its image user is uid/gid 1000
metabase H2 files are commonly owned by uid/gid 2000
```

Use `stat -c '%U:%G %a %n' <path>` and container `id` before changing ownership.

## Ports and Public Reachability

```text
443    public      HTTPS; nginx proxies / to 4080, /metabase to 3000, /logs to 5601
4063   public      OMERO.insight
4064   public      OMERO.insight SSL
4080   localhost   OMERO.web, reached through nginx
3000   localhost   Metabase, reached through nginx
5601   localhost   OpenSearch Dashboards, reached through nginx
9200   localhost   OpenSearch API
```

There is no host firewall on this VM. `ufw` is inactive and the iptables INPUT
policy is ACCEPT, so reachability is decided in the SURF Research Cloud
interface, not on the host. If OMERO.insight cannot connect on 4063/4064 while
the stack is healthy, the ports are almost certainly not open SURF-side; nothing
on the VM will show a block.

Check what actually answers from the VM:

```bash
for p in 443 4063 4064; do
  timeout 5 bash -c "echo > /dev/tcp/$(hostname -f)/$p" 2>/dev/null \
    && echo "$p open" || echo "$p closed/filtered"
done
```

4080, 3000 and 5601 being filtered is correct; they are published on the host
for nginx and local debugging only.

If the public URL does not answer at all, the nginx location block is probably
missing. `make doctor` reports this.

## Per-VM Values

Three settings are specific to the host and are wrong on any fresh clone:

```text
OMERO_CSRF_TRUSTED_ORIGINS
METABASE_SITE_URL
OBSERVABILITY_ROOT_URL
```

A wrong `OMERO_CSRF_TRUSTED_ORIGINS` is the nastiest failure here: every
container starts, all smoke tests pass, and OMERO.web login fails with an error
that does not name the cause. Fix all three at once:

```bash
make set-host HOST=$(hostname -f)
make up
```

`make doctor` compares them against `hostname -f` and warns on any mismatch.

## Project-Local SSH

Do not blindly mount host `~/.ssh` directly to the worker's final SSH directory. Host SSH permissions can be incompatible with the container user and can produce nested `.ssh/.ssh` state after restarts.

The intended pattern is:

```yaml
biomeroworker:
  volumes:
    - "./.ssh:/tmp/.ssh:ro"
```

Then `biomeroworker/10-mount-ssh.sh` copies `/tmp/.ssh/.` into `/opt/omero/server/.ssh` on every startup, replacing old contents:

```bash
rm -rf /opt/omero/server/.ssh
mkdir -p /opt/omero/server/.ssh
cp -R /tmp/.ssh/. /opt/omero/server/.ssh/
chmod 700 /opt/omero/server/.ssh
chmod 600 /opt/omero/server/.ssh/*
chmod 644 /opt/omero/server/.ssh/*.pub
chmod 644 /opt/omero/server/.ssh/known_hosts
```

Repo-local `.ssh/config` may contain deploy aliases such as:

```text
Host biomero-prod
  HostName <ip>
  User <user>
```

Use `ssh -F .ssh/config biomero-prod ...` if the alias is not in `~/.ssh/config`.

The current `biomero-prod` entry points at a deleted VM and refuses connections. Commands in this skill that target it are the right pattern but cannot run until a replacement is provisioned and the `HostName` is updated. Until then, everything runs on the dev workspace.

## Deploy Script Permission Workarounds

`scripts/deploy-local-stack.sh` creates expected bind-mount paths and applies pragmatic permissions:

```bash
mkdir -p .ssh web/L-Drive logs/omeroserver logs/omeroworker-1 logs/biomeroworker logs/omeroweb logs/biomero-importer
chmod 700 .ssh
chmod 600 .ssh/$SLURM_ACCESS_KEY
chmod 644 .ssh/$SLURM_ACCESS_KEY.pub .ssh/known_hosts .ssh/config
sudo chmod -R 777 web/L-Drive logs
sudo chmod 666 web/slurm-config.ini web/biomero-config.json web/group-mappings.json
sudo chown -R 1000:1000 logs/biomero-importer
sudo chmod -R 775 logs/biomero-importer
```

Treat broad `777` as a compatibility workaround for mixed host/container users, not a security ideal. Prefer targeted ownership or ACLs once writer UIDs are known.

The cluster key is always addressed as `$SLURM_ACCESS_KEY` (from `.env`, defaulting to `slurm_access_key`), never by a literal filename. A hardcoded `id_rsa` once survived in this script after the key was renamed, and because the script runs under `set -euo pipefail`, the missing path aborted the whole deploy on a message that names no cause:

```text
chmod: cannot access '.../.ssh/id_rsa': No such file or directory
make: *** [Makefile:99: deploy] Error 1
```

When `make deploy` dies on a bare `chmod`/`cp`/`ln` error immediately after preflight passes, suspect a stale hardcoded path rather than a real permission problem: preflight resolves the key through `$SLURM_ACCESS_KEY` and passes, then the deploy script fails on a name preflight never checked. Grep the scripts for the literal name before anything else.

`id_rsa` in `README.md` and `docs/sysadmin/slurm-integration.md` is upstream NL-BIOMERO documentation for a generic local-Slurm dev setup using the developer's own `~/.ssh/id_rsa`. It is unrelated to this deployment's cluster key and is not drift; leave it.

`scripts/render-slurm-config.sh` renders `web/slurm-config.ini` from `web/slurm-config-template.ini` and sets mode `0666` because OMERO.biomero writes the bind-mounted config from `omeroweb` as uid 999.

## Compose Differences

Production `docker-compose.yml`:

- uses built images and normal entrypoints
- mounts `./.ssh:/tmp/.ssh:ro` for the worker
- exposes OMERO, OMERO.web, and Metabase on host ports
- uses `profiles: ["IMPORTER_ENABLED"]` for `biomero-importer`
- mounts `./web/L-Drive:/data` consistently
- mounts `./metabase:/metabase-data`

Development `docker-compose-dev.yml`:

- mounts adjacent source checkouts for `../OMERO.biomero` and `../OMERO.forms`
- leaves `omeroweb` at `tail -f /dev/null` for manual web-process debugging
- mounts importer source/config/logs for live iteration
- may include `tus-destination` and extra group-mapping files

Do not assume dev compose behavior is suitable for prod.

## Metabase Application Database

Metabase stores its own dashboards, users and settings in an **application
database**, separate from the BIOMERO analytics data it charts. Since
2026-09-17 that is Postgres, in a `metabase` database on `database-biomero`:

```yaml
MB_DB_TYPE: postgres
MB_DB_HOST: database-biomero
MB_DB_DBNAME: metabase
```

There is no bind mount any more. The data lives in the `database-biomero`
volume and is covered by that volume's backup.

### Why not H2

Upstream shipped `MB_DB_FILE: /metabase-data/metabase.db` with `./metabase`
bind-mounted, unchanged since 2024-08. H2 treats the value as a path *prefix*
and creates `metabase/metabase.db/metabase.db.mv.db`; the nesting is correct,
and `.gitignore` lists exactly those paths.

The trap is an **empty** `metabase/metabase.db/` directory, left by deleting the
`.mv.db` files without the folder, or by restoring a backup that archived the
directory but not its contents. H2 cannot create its store at the prefix and
retries forever:

```text
MVStoreException: The file is locked: /metabase-data/metabase.db/metabase.db.mv.db
Caused by: java.nio.channels.OverlappingFileLockException
```

It hides well: `/api/health` still returns 200 and dashboards still render,
because one connection holds the real file while a background task loops. The
only visible symptom is `metabase.db.trace.db` growing without bound, measured
at ~2.5 GB/day on this host -- roughly eighteen days to a full disk, and a full
disk is what corrupts the store in the first place.

Do not "fix" this by pointing `MB_DB_FILE` deeper. H2 appends another directory
level and the problem recurs one level down.

`make doctor` checks the Postgres setup, including that both embedded dashboard
IDs in `.env` exist and have embedding enabled.

### Migrating H2 to Postgres

Metabase's own `load-from-h2` preserves dashboard **IDs**, which matters because
OMERO.web embeds them by number via `METABASE_IMPORTS_DB_PAGE_DASHBOARD_ID` and
`METABASE_WORKFLOWS_DB_PAGE_DASHBOARD_ID`.

```bash
sudo docker compose stop metabase
sudo docker exec nl-biomero-database-biomero-1 \
  psql -U biomero -d postgres -c "CREATE DATABASE metabase OWNER biomero;"

# the H2 file must be WRITABLE: load-from-h2 runs migrations on the source first
sudo docker run --rm --network nl-biomero_omero -v "$PWD/h2dir:/h2" \
  -e MB_DB_TYPE=postgres -e MB_DB_HOST=database-biomero -e MB_DB_PORT=5432 \
  -e MB_DB_DBNAME=metabase -e MB_DB_USER=biomero -e MB_DB_PASS=<pass> \
  --entrypoint java metabase/metabase@sha256:<pin> \
  -jar /app/metabase.jar load-from-h2 /h2/metabase.db
```

Pass the H2 path **without** the `.mv.db` suffix. Then switch `MB_DB_*` in
compose and drop the `./metabase` volume.

Note that `/api/session/properties` reports `enable-embedding: null` to
unauthenticated callers even when embedding is on; read the `setting` table to
check it for real:

```bash
sudo docker exec nl-biomero-database-biomero-1 psql -U biomero -d metabase \
  -c "SELECT key,value FROM setting WHERE key LIKE '%embedding%';"
```

### Backups

`backup_and_restore/backup/backup_metabase.sh` archived the `./metabase` folder.
With no folder to archive it now dumps the Postgres database instead, writing
`metabase.{timestamp}.pg_dump`:

```bash
CONTAINER_ENGINE="sudo docker" ./backup_and_restore/backup/backup_metabase.sh
```

`CONTAINER_ENGINE` is needed on this host because the Docker socket is
root-only. Restore with `pg_restore -U biomero -d metabase --clean`.

The `metabase` database also sits on `database-biomero`, so the existing
`database-biomero` volume backup already covers it; the dump is for restoring
Metabase alone without touching the analytics data.

### File ownership, for an H2 deployment

If you are still on H2, the live file is locked while Metabase runs. For read
inspection, copy it inside the container and query the copy. For writes, stop
Metabase first and back up the folder:

```bash
sudo docker compose stop metabase
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p backups
sudo tar -czf "backups/metabase.pre-change.$TS.tar.gz" metabase
```

When copying a working `metabase/` folder between hosts, preserve numeric ownership:

```bash
tar --numeric-owner -czf - metabase | ssh -F .ssh/config biomero-prod '
  cd /opt/omero/NL-BIOMERO &&
  sudo rm -rf metabase &&
  sudo tar --numeric-owner -xzf -
'
```

After cross-host copy, repair datasource credentials for the target environment; the H2 DB carries database passwords, admin users, and embedding settings.

## The Importer Always Links, Never Copies

`BIOMERO.importer` v1.4.2 passes `--transfer=ln_s` to every import. It is a
hardcoded default in `biomero_importer/utils/importer.py` -- a keyword default
on `import_to_omero` and `import_dataset`, plus string literals at the call
sites -- with no setting, environment variable or order field to change it.

So the managed repository holds symlinks into `/data`, not pixels:

```bash
docker exec nl-biomero-omeroserver-1 \
  find /OMERO/ManagedRepository -type l -exec readlink {} \;
```

Two consequences:

- **Delete or move a file under `/data` and its OMERO image dies.** It becomes
  unreadable with `ResourceError: Error instantiating pixel buffer`, and in a
  workflow that surfaces two steps later as a misleading
  `SLURM_Remote_Conversion.py` ValidationException.
- **The backup does not cover those pixels.** `backup_server.sh` runs a plain
  `tar -czf` with no `--dereference`, so it archives the dangling symlinks
  themselves. A restore brings back 0-byte links.

Workflow results are linked out of `/data/root/.analyzed/`, which is scratch
space, so imported masks are the most exposed of all.

Check for images whose source has already gone:

```bash
docker exec nl-biomero-omeroserver-1 bash -lc \
  'find /OMERO/ManagedRepository -type l ! -exec test -e {} \; -print'
```

To import pixels into the `/OMERO` volume, where the backup does cover them, use
OMERO.insight or the `omero import` CLI without `--transfer`, not the BIOMERO
Importer. Adding `--dereference` to the backup tar would capture the pixels but
not fix the fragility, and would inflate every archive.

## Importer Privilege Model

`biomero-importer` runs Podman inside the container. The current operational model requires:

```yaml
privileged: true
devices:
  - "/dev/fuse:/dev/fuse"
security_opt:
  - "label=disable"
```

The importer image is built around `autoimportuser:autoimportgroup` uid/gid `1000:1000`, rootless Podman mappings, `fuse-overlayfs`, setuid `newuidmap/newgidmap`, and writable `/auto-importer/logs`.

If preprocessing containers cannot start, test internal Podman:

```bash
sudo docker exec -it nl-biomero-biomero-importer-1 podman info
sudo docker exec -it nl-biomero-biomero-importer-1 podman run docker.io/godlovedc/lolcow
```

If logs cannot be written, check host `logs/biomero-importer` ownership and mode for uid/gid 1000.

## OMERO.forms and Web Config

`web/45-fix-forms-config.sh` uses a private `mktemp -d` scratch dir and `envsubst` to render `/opt/omero/web/config/01-default-webapps.omero`. This replaced an older predictable `/tmp/forms-config` pattern. Keep scratch dirs private for startup scripts that process env-derived config.

`web/44-create_forms_user.py` creates/validates the forms master user. If forms startup fails, check `omeroweb` logs before changing OMERO user/group state.

## Disk Space and Log Growth

The host root filesystem is small relative to what Docker can accumulate. A full disk breaks things that look unrelated: VS Code Remote-SSH fails with `UnpackFailed` because it cannot extract the server tarball, containers fail to start, and Postgres/OpenSearch can flip into a read-only protective mode.

Check quickly:

```bash
df -h /
sudo du -sxh /var/lib/docker/* 2>/dev/null | sort -rh | head
sudo docker system df -v
```

Ordinary, safe-to-reclaim space (does not touch running containers or their data):

```bash
sudo docker image prune -a -f      # dangling/unused images only
sudo journalctl --vacuum-time=3d   # systemd journal, self-regrows, safe to trim
```

Before removing any image shown as reclaimable, confirm with `docker inspect <container> --format='{{.Image}}'` that no running container actually references it — a tag can be reassigned to a new build while a running container still holds the old image ID, so the stale tag looks orphaned but the digest under it may not be.

Stale `~/.vscode-server` installs from failed/interrupted remote connections can also hold several GB; safe to `rm -rf ~/.vscode-server` on the affected user, VS Code reinstalls it on next connect.

### Runaway container logs

Docker's `json-file` log driver has no size cap unless a service sets one.

Since `345af643` every service in `docker-compose.yml`, `docker-compose-dev.yml`,
`opensearch-compose.yml` inherits a 10m x 5 cap from
`logging-defaults.yml`. Before that, five OMERO services already set the same
values inline; the commit unified those and covered the three that had none --
`database`, `database-biomero`, `metabase` -- plus the whole log stack, where
`opensearch` had grown a single 2.6 GB file.

**Caps apply on container re-creation, not restart.** `docker compose up -d`
only recreates services whose config changed, so a container that was already
running keeps its old (uncapped) setting until something forces it to be
recreated. Check what is actually in effect rather than what the file says:

```bash
sudo docker ps --format '{{.Names}}' | while read n; do
  sudo docker inspect -f '{{.Name}} {{.HostConfig.LogConfig.Config}}' "$n"
done
```

`make doctor` reports this. Note the log stack is a separate compose file, so it
needs its own `docker compose -f opensearch-compose.yml up -d`. A container stuck retrying a failing action logs one entry per attempt and can grow a single log file to tens of GB, which is a much larger and faster space drain than image/volume growth. Find the actual offender by log file size, not just image/volume size:

```bash
sudo find /var/lib/docker/containers -name '*-json.log' -exec du -h {} \; | sort -rh | head
```

If one file dominates, `sudo docker logs <container> --tail 50` (or `tail` the file directly) to see what is looping before deciding whether to just truncate the log or also fix the underlying loop. Truncating in place is safe and does not require a restart:

```bash
sudo truncate -s 0 /var/lib/docker/containers/<id>/<id>-json.log
```

OpenSearch specifically has a self-reinforcing failure mode worth recognizing: once disk usage crosses its flood-stage watermark, it marks indices read-only, including its own audit-log index. Every subsequent request then fails to audit-log, which OpenSearch reports as an `ERROR` with a full stack trace — for every request — which fills the disk further and keeps the watermark tripped. Truncating the log does not fix this; the block has to be lifted via the OpenSearch API once space exists, or the log regrows immediately.

Every service in `docker-compose.yml`, `docker-compose-dev.yml` and `opensearch-compose.yml` gets its log driver from `logging-defaults.yml`, a single shared stub service (`max-size: 10m`, `max-file: 5`, so roughly 50MB cap per container) pulled in per-service via:

```yaml
extends:
  file: logging-defaults.yml
  service: default-logging
```

`extends` is used instead of a YAML anchor because anchors do not resolve across separate files — each compose file parses independently, so an anchor defined in one file is invisible in another even under `include:`. `extends` genuinely merges from the external file, so `logging-defaults.yml` is the one real source; changing the cap there changes it everywhere. Any new service added to these files needs the same `extends:` block or it reverts to Docker's unbounded default.

## Backup Guardrails

Before mutating live prod state:

- Identify host and stack path.
- Back up the file/folder being changed.
- Stop services that hold locks, especially Metabase.
- Avoid `git checkout --`, `git reset --hard`, or deleting volumes unless explicitly requested.
- Use `sudo docker compose ps` and targeted logs after restart.

Optional logging stack (`opensearch-compose.yml`) can leave orphan containers when normal compose is restarted. This is not necessarily a stack failure.
