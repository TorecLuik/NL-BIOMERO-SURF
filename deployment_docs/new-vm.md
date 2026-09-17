# Deploying to a New VM

*Created 2026-09-16 · last updated 2026-09-17*

Standing up NL-BIOMERO on a fresh SURF Research Cloud VM is two commands with
one manual stop between them:

```bash
# attach the storage volume in the portal first -- it carries the data
# and the secrets. See storage-architecture.md.
make provision              # host packages, submodule, hostname, nginx
make init                   # submodules, and link .env/.ssh at the volume
# open ports 4063 and 4064
make set-host HOST=$(hostname -f)
make deploy                 # build, start, smoke test
```

Budget about an hour, most of it image builds.

Most of this could become a Research Cloud catalog item, so that creating a
workspace does it instead. See [catalog-item-migration.md](catalog-item-migration.md)
for what that would replace and what it would not.

## What cannot be automated

Three things have to be done by hand. `provision-vm.sh` checks the last two and
reports whether the secrets resolved; it cannot see the portal, so it cannot
tell you whether the volume is attached — only that the files it expects are
missing.

**Attaching the storage volume.** The volume carries the data *and* the
secrets, so nothing deploys without it. Creating and attaching it is dashboard
work: a volume attaches to one workspace at a time, and attaching to a running
workspace means pausing it first. `.env` and `.ssh/` are no longer hand-copied
archives — they live in `config/` on that volume.

**Ports 4063 and 4064.** OMERO.insight connects directly to these. There is no
host firewall on this VM, so they are opened in the SURF Research Cloud
interface, which has no API reachable from inside the VM. Everything else is
proxied through nginx on 443, so no other port needs opening.

**The Spider key.** If the SSH key is new rather than restored, its public half
has to be authorised on Spider for `SPIDER_USER`.

## 1. Clone

```bash
sudo mkdir -p /opt/omero && sudo chown "$USER" /opt/omero
cd /opt/omero
git clone <repo-url> NL-BIOMERO
cd NL-BIOMERO
```

## 2. Prepare the host

```bash
make provision
```

`make provision` takes no arguments. For the flags, call the script directly:
`scripts/provision-vm.sh --skip-packages` when the host already has Docker and
git, or `--no-nginx` to leave the host's nginx alone.

It installs docker, compose, git, make and htpasswd; fetches the
`biomero-importer` submodule; sets the three per-VM hostname values from
`hostname -f`; installs the nginx location block and reloads nginx. Then it
reports on the three manual items and exits non-zero while any is outstanding.

Flags: `--skip-packages` if the host already has them, `--no-nginx` to leave
host nginx alone.

## 3. Link the secrets from the storage volume

`.env` and `.ssh/` are no longer restored by hand. They live in `config/` on the
attached storage volume, and the repository reaches them through symlinks:

```bash
make link-config            # or make init, which also runs this
ssh -F .ssh/config spider 'sinfo -s | head'   # confirm the key works
```

Because `.env` travels with the volume, it carries the *previous* machine's
hostname. Set this one:

```bash
make set-host HOST=$(hostname -f)
```

If the volume is new and has no `config/` yet, see
[storage-architecture.md](storage-architecture.md) for how to populate one.

## 4. Open the OMERO.insight ports

In the SURF Research Cloud interface, open `4063` and `4064` to the networks
that need OMERO.insight. Re-run `make provision` to confirm; it probes
both and warns while either is unreachable.

## 5. Deploy

```bash
make deploy
```

Preflight, build, start, then smoke tests: services running, both databases
answering, the web login page, installed versions against the pins, the runtime
patch, Spider reachability, the log stack, and the public URL.

If the host was not fully prepared, preflight says so and refuses to deploy.

## 6. Restore data, if this replaces an existing deployment

Volumes and stack configs come from the backup, with restore commands in its
`MANIFEST.md`:

```text
/data/storage_hpc/biomero-backup-2026-09-15/
```

Metabase is the exception. Its dashboards live in a `metabase` database on
`database-biomero`, so they arrive with that volume; the `metabase-h2.tar.gz` in
older backups predates the move and is only useful for a one-off
`load-from-h2` migration. `make deploy` creates the database if it is missing,
so a genuinely fresh deployment starts with an empty Metabase and the two
`METABASE_*_DASHBOARD_ID` values in `.env` will not resolve until dashboards
exist. See the expert skill, "Metabase Application Database".

Restore with the stack stopped (`make down`), then `make up`.

## 7. Verify what the smoke tests cannot

These need real data or a browser:

```text
run a CPU workflow, a MIG GPU workflow, and deconvolve_plate on full A100
confirm workflow results import back into OMERO
drop files under /data and confirm the importer picks them up
open OMERO.web and check the Metabase dashboards embed
open /logs and confirm the log viewer renders behind basic auth
connect OMERO.insight on 4063/4064
```

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

Only 443, 4063 and 4064 should be reachable from outside. The rest are published
on the host for nginx and local debugging.

## Spider

Nothing needs creating there. `/project/<project>/Share/biomero/` already holds
`data/`, `slurm-scripts/` and `singularity_images/`, and BIOMERO regenerates job
scripts and pulls missing container images on demand.

## If something is wrong

```bash
make doctor   # submodule, pins, images, hostname, public URL
make ps       # all containers, log stack included
make logs:SVC # follow one service
```
