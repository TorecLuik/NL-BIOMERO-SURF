# Deploying to a New VM

*Created 2026-09-16 · last updated 2026-09-17*

Standing up NL-BIOMERO on a fresh SURF Research Cloud VM is two commands with
one manual stop between them:

```bash
# attach the storage volume in the portal first -- it carries the data and
# the credentials that unlock it. See storage-architecture.md.
make provision              # host packages, submodule, nginx
make init-env               # writes .env, generating every secret
make new-key                # then register the public half on Spider
make init                   # submodule, rendered config, hostname, /logs auth
# open ports 4063 and 4064
make deploy                 # build, start, smoke test
make install-services       # production: start at boot, nightly backup
```

Budget about an hour, most of it image builds.

## What cannot be automated

Three things have to be done by hand. `provision-vm.sh` checks the last two and
reports whether the secrets resolved; it cannot see the portal, so it cannot
tell you whether the volume is attached — only that the files it expects are
missing.

**Attaching the storage volume.** The volume carries the data and the
credentials that unlock it, so nothing deploys without it. Creating and
attaching it is dashboard work: a volume attaches to one workspace at a time,
and attaching to a running workspace means pausing it first. `.env` and `.ssh/`
are *not* on the volume: they belong to the VM, and `volume-identity` is the
only thing that travels with the data.

**Ports 4063 and 4064.** OMERO.insight connects directly to these. There is no
host firewall on this VM, so they are opened in the SURF Research Cloud
interface, which has no API reachable from inside the VM. Everything else is
proxied through nginx on 443, so no other port needs opening.

**The Spider key.** If the SSH key is new rather than restored, its public half
has to be authorised on Spider for `SPIDER_USER`.

## 1. Clone

Owned by the admins' group rather than one person, so the deployment does not
depend on any single account:

```bash
sudo mkdir -p /opt/omero
sudo chown root:<admin-group> /opt/omero && sudo chmod 2775 /opt/omero
sudo git config --system http.version HTTP/1.1   # see runbook.md, Known Issues
cd /opt/omero
git clone <repo-url> NL-BIOMERO
cd NL-BIOMERO
git config core.sharedRepository group
```

## 2. Prepare the host

```bash
make provision
```

`make provision` takes no arguments. For the flags, call the script directly:
`scripts/provision-vm.sh --skip-packages` when the host already has Docker and
git, or `--no-nginx` to leave the host's nginx alone.

It installs git, make and curl, and Docker and the compose plugin where
missing (an existing Docker CE is left alone); fetches the
`biomero-importer` submodule; sets the three per-VM hostname values from
`hostname -f`; installs the nginx location block and reloads nginx. Then it
reports on the three manual items and exits non-zero while any is outstanding.

## 3. Create this VM's secrets

`.env` and `.ssh/` belong to the VM, not to the volume. Neither is in git, and
neither comes from the storage volume: `.env` carries this machine's hostname
and pins, and the cluster key is an authorisation granted on Spider.

```bash
make init-env               # asks for SPIDER_USER and SPIDER_PROJECT, generates the rest
make new-key                # the cluster key, if it is not being reused
make init                   # renders slurm-config.ini, sets the hostname
```

`make render-config` writes `web/slurm-config.ini` from the committed template
and this VM's `.env`. Nothing on the volume is involved: admin-UI edits to that
file are not preserved, so a change worth keeping goes in the template.

Some values go the other way, because they are fixed by the data. On a volume that already holds data, delete `POSTGRES_PASSWORD`,
`BIOMERO_POSTGRES_PASSWORD` and `METABASE_SECRET_KEY` from the generated `.env`:
`make deploy` fills them from `config/volume-identity` and stops if `.env`
carries different ones. Set `OMERO_ROOT_PASSWORD`, `OMERO_IMPORTER_PASSWORD`
and `FORMS_MASTER_PASSWORD` to the volume's existing values too; those accounts
live in the OMERO database, and `volume-identity` does not record them. See
[storage-architecture.md](storage-architecture.md).

Once the key is registered and the stack deployed, `make check` confirms Spider
is reachable.

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

Attach the existing volume instead of an empty one; its data and credentials
come with it. To fill an empty volume from another deployment or from a
backup, see [storage-architecture.md](storage-architecture.md#populating-a-volume-that-is-empty)
and the restore steps in [runbook.md](runbook.md#restoring-a-database).

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

Only 443, 4063 and 4064 are public; every other port is bound to loopback. The
full list is in [deployment.md](deployment.md#ports).

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
