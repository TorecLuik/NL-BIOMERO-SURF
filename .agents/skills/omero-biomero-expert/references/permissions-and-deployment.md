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
4080   loopback    OMERO.web, reached through nginx
3000   loopback    Metabase, reached through nginx
5601   loopback    OpenSearch Dashboards, reached through nginx
9200   loopback    OpenSearch API, no authentication
9300   loopback    OpenSearch transport
9600   loopback    OpenSearch Performance Analyzer
```

Compose binds every backend port to `127.0.0.1`, so none of them is reachable
from outside whatever the network rules say. Keep it that way: OpenSearch has
no authentication, and a directly reachable 5601 bypasses the `/logs` basic
auth. `sudo ss -ltnp` shows the binding; anything but `127.0.0.1` on those
ports is a regression. To reach one from a workstation, tunnel:
`ssh -L 5601:localhost:5601 <host>`.

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

4080, 3000 and 5601 being closed from outside is correct; they listen on
loopback for nginx only.

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
    - "./.ssh-worker:/tmp/.ssh:ro"
```

`.ssh-worker/` is the deploy's group-readable copy of `.ssh/`: the container
reads the key as "other", while OpenSSH on the host refuses a key anyone else
can read, so one directory cannot serve both. `.ssh/` stays `0700`, owned by
whoever ran `make new-key`.

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

Repo-local `.ssh/config` holds the cluster hosts only (`spider`, and upstream's
`localslurm`), written by the deploy. It is not a way to reach the VMs; those
are plain `ssh <address>`, listed in SKILL.md.

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
sudo docker compose exec -T database-biomero \
  psql -U biomero -d postgres -c "CREATE DATABASE metabase OWNER biomero;"

# the network name is derived from the checkout directory, so read it back
net=$(sudo docker inspect -f \
  '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' metabase)

# the H2 file must be WRITABLE: load-from-h2 runs migrations on the source first
sudo docker run --rm --network "$net" -v "$PWD/h2dir:/h2" \
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
sudo docker compose exec -T database-biomero psql -U biomero -d metabase \
  -c "SELECT key,value FROM setting WHERE key LIKE '%embedding%';"
```

### Backups

The nightly backup dumps the `metabase` database with the others (see Backup
Guardrails). Restoring Metabase alone, without touching the analytics data:
`pg_restore -U biomero -d metabase --clean` from its `metabase.pg_dump`.

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
sudo docker compose exec -T omeroserver \
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

Workflow results are linked out of `/data/<user>/.analyzed/`. It looks like a
scratch directory but holds the only copy of the result pixels, so imported
masks are the most exposed of all: clearing it breaks every one of them.

Check for images whose source has already gone:

```bash
sudo docker compose exec -T omeroserver bash -lc \
  'find /OMERO/ManagedRepository -type l ! -exec test -e {} \; -print'
```

To import pixels into the `/OMERO` volume, where the backup does cover them, use
OMERO.insight or the `omero import` CLI without `--transfer`, not the BIOMERO
Importer. Adding `--dereference` to the backup tar would capture the pixels but
not fix the fragility, and would inflate every archive.

## Values the Data Depends On

A few values are read once, when what they protect is first created, and
ignored afterwards: both Postgres passwords, `METABASE_SECRET_KEY`, the OMERO
root password (`ROOTPASS` only applies at `omego db init`), the forms master's
name, and Metabase's admin login. **Never regenerate them for existing data.**
The stack would start, then fail to log in with errors that do not name the
cause. The importer's password follows root's when it logs in as root.

They are recorded next to the data in `<data>/config/volume-identity` (0600,
read through `sudo`), and `scripts/volume-identity.sh` is the only thing that
should write it:

```bash
./scripts/volume-identity.sh check    # fill unset values from the record; fail on disagreement
./scripts/volume-identity.sh keys     # the list
make adopt-volume                     # record a volume that has none, or add keys an old record lacks
./scripts/volume-identity.sh rotate BIOMERO_POSTGRES_PASSWORD   # or POSTGRES_PASSWORD
```

- `make init-env` on a volume that has a record leaves these keys as
  `CHANGE ME`; `make deploy` fills them. Preflight runs the fill before its
  completeness check.
- `adopt` verifies each value against the service that holds it -- a network
  Postgres login, an OMERO login, a Metabase login -- before writing.
- After `rotate`: `make up` (containers read `.env` at start), then
  `scripts/restore-metabase-dashboards.sh` (Metabase keeps its own copy of the
  BIOMERO password for its datasource).

## Boot and Restart

Every service is `RestartPolicy: "no"` on purpose: if Docker started Postgres
before the data volume mounted, it would initialise an empty cluster on the
boot disk and look healthy. `nl-biomero.service` (installed by
`make install-services`) runs `make up` at boot with `RequiresMountsFor=` the
data path, and `make down` at shutdown. `nl-biomero-backup.timer` runs the
nightly backup.

After pausing and resuming the workspace, or reattaching the volume later than
boot: `make ps`, and if the stack is down, `sudo systemctl restart nl-biomero`.
`make doctor` warns when either unit is missing.

## Git over HTTPS on Ubuntu 22.04

`git clone` or `git submodule update` from GitHub failing with "could not read
Username", even for a public repository, is libcurl 7.81 mishandling GitHub's
HTTP/2 `103 Early Hints`: it turns the following response into a bogus `401`.
`git config --system http.version HTTP/1.1` fixes it; `make provision` sets it,
but the first clone on a new VM comes before that. `GIT_TRACE_CURL=1` shows
`200`, `103`, `401` in a row when this is the cause.

## Private Notes

`deployment_docs/private/` is gitignored and exists only on the prod VM,
group-readable by the admins. It holds notes for the maintainers that must not
be published before private disclosure, e.g. a security report. Never copy its
contents into a tracked file, a commit message or an upstream issue.

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
sudo docker compose exec -T biomero-importer podman info
sudo docker compose exec -T biomero-importer podman run docker.io/godlovedc/lolcow
```

If logs cannot be written, check host `logs/biomero-importer` ownership and mode for uid/gid 1000.

## OMERO.forms and Web Config

`web/45-fix-forms-config.sh` uses a private `mktemp -d` scratch dir and `envsubst` to render `/opt/omero/web/config/01-default-webapps.omero`. This replaced an older predictable `/tmp/forms-config` pattern. Keep scratch dirs private for startup scripts that process env-derived config.

`web/44-create_forms_user.py` creates/validates the forms master user. If forms startup fails, check `omeroweb` logs before changing OMERO user/group state.

## The /logs Viewer

`/logs` is OpenSearch Dashboards behind nginx basic auth. The credentials are
`NGINX_LOGS_USER` and `NGINX_LOGS_PASSWORD` in `.env` -- they are what the
browser asks for, and OpenSearch has no separate login in this deployment.
`make logs-auth` writes them to `/etc/nginx/.htpasswd`; without that file nginx
answers 401 on `/logs` while the rest of the site works.

**Answering is not the same as being usable.** The viewer can be up with every
log shipped and indexed, and still open on a "create an index pattern" setup
screen showing nothing. The index template gives the data its field types; the
Dashboards index pattern is a separate saved object, and it is what makes any of
it browsable.

`dashboards-init` creates the `biomero-logs` pattern and sets it as default. It
is deliberately separate from `opensearch-init` because fluent-bit blocks on
that one, and this waits on Dashboards, which is much slower to start.

```bash
sudo docker logs dashboards-init
curl -s -H 'osd-xsrf: true' \
  'http://localhost:5601/logs/api/saved_objects/_find?type=index-pattern&per_page=20' \
  | grep -o 'biomero-logs'
```

`scripts/bootstrap-prod.sh` smoke-tests both claims separately. Re-running
`dashboards-init` recreates the pattern; `opensearch/init-dashboards.sh` is
idempotent, answering 409 when it already exists.

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

Two things made that watermark much easier to reach, both now fixed.

**The disabled security plugin wrote an audit log anyway.** `plugins.security.disabled=true`
does not stop it; the audit log is a separate switch, and on the QA VM it had
reached 692MB against 56MB of real logs. `opensearch-compose.yml` now also sets
`plugins.security.audit.type=noop` with `enable_rest` and `enable_transport`
false. If a `security-auditlog-*` index reappears, that config did not take --
the container was restarted rather than recreated.

**Nothing aged anything off.** OpenSearch keeps every document forever unless an
ISM policy says otherwise, and there was none, so `biomero-logs` grew for the
life of the deployment with a full volume as the first symptom.
`opensearch/retention-policy.json` rolls over at 20GB or 7 days and deletes at
90; tune the ages there rather than in the script.

```bash
make logs-retention   # apply the policy, clear leftover audit indices

curl -s 'http://localhost:9200/_cat/indices/security-auditlog-*?h=index,store.size'
curl -s 'http://localhost:9200/_plugins/_ism/policies/biomero-logs-retention' | head -c 200
```

`scripts/apply-opensearch-retention.sh` is safe to re-run and runs from
`make deploy`, though not under `START_LOG_STACK=0`. Updating an existing policy
needs its current `_seq_no`/`_primary_term`, read back from the policy -- a 409
body is an error, not the policy.

**A registered policy is not an applied one.** Its `ism_template` only adopts
indices created *after* the policy exists, and fluent-bit creates `biomero-logs`
on its first flush -- usually before the script runs, since the same compose up
starts both. The policy then exists, matches the index by pattern, and manages
nothing. `4ef7b75a` attaches it explicitly; check rather than assume:

```bash
curl -s 'http://localhost:9200/_plugins/_ism/explain/biomero-logs' \
  | grep -oE '"total_managed_indices":[0-9]+'    # 0 means nothing is ageing off
```

**Rollover needs `biomero-logs` to be a write alias, not an index.** ISM rolls an
alias onto a fresh backing index; against a plain index of a fixed name the hot
state has nothing to act on, so only the 90-day delete applies. `init-opensearch.sh`
now creates `biomero-logs-000001` with `biomero-logs` as its write alias, but a
name cannot be both -- a deployment that predates this keeps its concrete index
and gets no rollover. Converting it means reindexing, so it is a maintenance
window, not a start-up task; `apply-opensearch-retention.sh` warns when it finds
that state.

```bash
curl -s 'http://localhost:9200/_cat/aliases/biomero-logs?h=alias,index,is_write_index'
```

Every service in `docker-compose.yml`, `docker-compose-dev.yml` and `opensearch-compose.yml` gets its log driver from `logging-defaults.yml`, a single shared stub service (`max-size: 10m`, `max-file: 5`, so roughly 50MB cap per container) pulled in per-service via:

```yaml
extends:
  file: logging-defaults.yml
  service: default-logging
```

`extends` is used instead of a YAML anchor because anchors do not resolve across separate files — each compose file parses independently, so an anchor defined in one file is invisible in another even under `include:`. `extends` genuinely merges from the external file, so `logging-defaults.yml` is the one real source; changing the cap there changes it everywhere. Any new service added to these files needs the same `extends:` block or it reverts to Docker's unbounded default.

## Backups

`scripts/backup-nightly.sh`, run at 02:30 by `nl-biomero-backup.timer` and on
demand by `make backup`, writes `<data>/backups/nightly/<timestamp>/`, root-only,
14 days kept:

```text
omero.pg_dump  biomero.pg_dump  metabase.pg_dump   from the running databases
omero-files.tar.gz                                 OMERO repository, no caches
secrets.tar.gz                                     .env, .ssh/, config/, web configs
SHA256SUMS
```

It is small -- megabytes -- because it holds structure, not pixels: users,
metadata, annotations, ROIs, tables, job history, dashboards, credentials. The
pixels are in L-Drive, which it does not copy: imported images and workflow
results are symlinks into `L-Drive`, including `<user>/.analyzed/`, which is
the only copy of the result pixels and must never be cleaned up. The backups
sit on the same volume as the data, so they cover a bad upgrade or a deletion,
not losing the volume.

Restoring a database: only the databases may run, since OMERO and the workers
hold connections a `--clean` restore collides with; and the directory is
root-only, so read it through `sudo`:

```bash
make down && sudo docker compose up -d database database-biomero
sudo cat $B/omero.pg_dump | sudo docker compose exec -T database pg_restore -U omero -d omero --clean --if-exists
make up
```

When unsure which night to use, restore into a scratch database first
(`createdb`, `pg_restore -d <scratch>`, check, `dropdb`).

## Backup Guardrails

Before mutating live prod state:

- Check that no workflow or import is running and ask the operator (SKILL.md).
- Identify host and stack path.
- Back up the file/folder being changed.
- Stop services that hold locks, especially Metabase.
- Avoid `git checkout --`, `git reset --hard`, or deleting volumes unless explicitly requested.
- Use `sudo docker compose ps` and targeted logs after restart.

Optional logging stack (`opensearch-compose.yml`) can leave orphan containers when normal compose is restarted. This is not necessarily a stack failure.
