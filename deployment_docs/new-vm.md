# Deploying to a New VM

*Created 2026-09-16 · last updated 2026-09-16*

Standing up NL-BIOMERO on a fresh SURF Research Cloud VM is two commands with
one manual stop between them:

```bash
make provision              # host packages, submodule, hostname, nginx
# restore .env and .ssh/, open ports 4063 and 4064
make deploy                 # build, start, smoke test
```

Budget about an hour, most of it image builds.

Most of this could become a Research Cloud catalog item, so that creating a
workspace does it instead. See [catalog-item-migration.md](catalog-item-migration.md)
for what that would replace and what it would not.

## What cannot be automated

Three things have to be done by hand, and `provision-vm.sh` checks all three
rather than assuming them.

**The secrets.** `.env` and `.ssh/` exist only in your archive. `.env` is the
only copy of the deployment secrets; there is no `.env.secrets` to render it
from. A script that could fetch these unattended would be a worse security
posture than the manual step.

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

## 3. Restore the secrets

```text
.env            deployment secrets; the only copy
.ssh/id_rsa     Spider key, plus id_rsa.pub, known_hosts and config
```

```bash
chmod 600 .env .ssh/id_rsa
chmod 644 .ssh/id_rsa.pub .ssh/known_hosts .ssh/config
ssh -F .ssh/config spider 'sinfo -s | head'   # confirm the key works
```

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
