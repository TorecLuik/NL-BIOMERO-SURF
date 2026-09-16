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
mkdir -p .ssh ~/.ssh web/L-Drive logs/omeroserver logs/omeroworker-1 logs/biomeroworker logs/omeroweb logs/biomero-importer
chmod 755 .ssh
chmod 644 .ssh/config .ssh/known_hosts .ssh/id_rsa .ssh/id_rsa.pub
sudo chmod -R 777 web/L-Drive logs
sudo chmod 666 web/slurm-config.ini web/biomero-config.json web/group-mappings.json
sudo chown -R 1000:1000 logs/biomero-importer
sudo chmod -R 775 logs/biomero-importer
```

Treat broad `777` as a compatibility workaround for mixed host/container users, not a security ideal. Prefer targeted ownership or ACLs once writer UIDs are known.

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

## Metabase File Ownership

Metabase H2 lives under:

```text
metabase/metabase.db/metabase.db.mv.db
```

The live file is locked while Metabase runs. For read inspection, copy it inside the container and query the copy. For writes, stop Metabase first and back up the folder:

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

## Backup Guardrails

Before mutating live prod state:

- Identify host and stack path.
- Back up the file/folder being changed.
- Stop services that hold locks, especially Metabase.
- Avoid `git checkout --`, `git reset --hard`, or deleting volumes unless explicitly requested.
- Use `sudo docker compose ps` and targeted logs after restart.

Optional logging stack (`opensearch-compose.yml`) can leave orphan containers when normal compose is restarted. This is not necessarily a stack failure.
