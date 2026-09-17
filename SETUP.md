# Setting Up This Deployment

Standing up this stack on a fresh SURF Research Cloud VM. The stack's data and
secrets live on an **attached storage volume**, not on the VM, so the volume is
a prerequisite rather than something you restore afterwards.

If you are looking for the upstream project, see [README.md](README.md). If you
want to know *why* the storage is split this way, see
[deployment_docs/storage-architecture.md](deployment_docs/storage-architecture.md).

## Before You Start

You need three things that cannot be created from inside the VM:

```text
the storage volume   attached in the Research Cloud portal, named omero-data
ports 4063 and 4064  opened in the portal, for OMERO.insight
the Spider key       already authorised for SPIDER_USER on Spider
```

On a volume that already holds a deployment, `.env` and `.ssh/` come with it,
so the key requirement is usually already satisfied. On a **fresh, empty
volume**, you have to put them there first — see
[What the Storage Volume Needs](#what-the-storage-volume-needs).

## Setup

```bash
# 1. confirm the volume mounted (the portal name becomes the directory name)
mount | grep /data/

# 2. clone and prepare the host
git clone <this repo> && cd NL-BIOMERO
make provision

# 3. submodules, and link .env/.ssh/slurm-config.ini at the volume
make init

# 4. .env came from the volume and carries the previous machine's hostname
make set-host HOST=$(hostname -f)

# 5. build and start -- about an hour, most of it image builds
make deploy
```

Then verify:

```bash
make doctor      # config drift, hostname, pins, public URL
make ps          # every container running
```

and log in to the web UI. `make doctor` passing is not the same as the stack
being usable.

## If the Volume Is Not Named `omero-data`

`OMERO_DATA_PATH` in `.env.shared` defaults to `/data/omero-data`, matching a
volume named `omero-data`. A volume with a different name mounts elsewhere, and
`make init` will say it cannot find `config/`.

Pass the mountpoint to `link-config`, in place of step 3:

```bash
make link-config DATA_PATH=/data/<volume-name>
git submodule update --init --recursive
```

`DATA_PATH` overrides both env files, so nothing in the repo needs editing.
From then on the volume's own `.env` carries the path and plain `make
link-config` is enough.

Note that spaces in a volume name become underscores in the mount path.

## What Each Step Assumes

| Step | Fails if |
| --- | --- |
| `make provision` | no sudo, no network for apt, or the image already ships Docker CE |
| `make init` | volume not attached, or no `config/` on it |
| `./scripts/render-slurm-config.sh` | `SPIDER_USER`/`SPIDER_PROJECT` unset in `.env` |
| `make set-host` | — |
| `make deploy` | preflight finds missing secrets, or Spider unreachable |

`make init` is the one that most often stops people, and it is almost always
the volume: either not attached, attached under a different name, or attached
but empty. Check `mount | grep /data/` first.

## If `make provision` Fails on Docker

On an image that already has Docker CE, `make provision` stops in the package
step:

```text
containerd.io : Conflicts: containerd
E: Error, pkgProblemResolver::Resolve generated breaks, this may be caused by
   held packages.
```

Nothing is broken. `provision` installs Ubuntu's `docker.io`, which depends on
Ubuntu's `containerd`; some SURF Research Cloud images already carry Docker's
own packages from `download.docker.com`, and `containerd.io` conflicts with
`containerd`. apt cannot hold both, so it refuses the whole transaction --
including the unrelated packages in the same command.

Check what is already there:

```bash
docker --version && docker compose version
dpkg -l | grep -E 'docker-ce|containerd'
```

If Docker CE and the compose plugin are present, skip the package step:

```bash
./scripts/provision-vm.sh --skip-packages
```

`provision` also installs `apache2-utils` for `htpasswd`, which is not part of
the conflict and may still be missing. Install it on its own:

```bash
sudo apt-get install -y apache2-utils
```

Do **not** resolve the conflict by letting apt install `docker.io`: it removes
Docker CE and swaps the container runtime underneath a volume that may hold
live Postgres data. Docker CE is the newer of the two and works with this
stack; the deployment needs a working `docker` and `docker compose`, not
Ubuntu's specific packaging of them.

## What the Storage Volume Needs

A freshly created volume mounts as an empty directory. This is what has to be
on it before the stack will run.

### The directory layout

```bash
V=/data/omero-data          # the portal volume name becomes the directory name
sudo mkdir -p $V/{database,database-biomero,omero,L-Drive,config,backups}
```

| Directory | Who fills it | Notes |
| --- | --- | --- |
| `database/` | Postgres, on first start | leave empty |
| `database-biomero/` | Postgres, on first start | leave empty |
| `omero/` | OMERO, on first start | leave empty |
| `L-Drive/` | you, or leave empty | user data, mounted as `/data` |
| `config/` | **you — see below** | the secrets; nothing else can supply them |
| `backups/` | `backup_master.sh` | leave empty |

Only `config/` genuinely has to be populated. The three data directories are
created empty and initialised by the containers: Postgres runs `initdb` into an
empty bind mount and takes ownership as uid 999 mode 0700, and OMERO builds its
repository tree (`Files/`, `Pixels/`, `ManagedRepository/`, `certs/`, …) as uid
1000. Do not pre-create anything inside them, and do not chown them yourself.

`L-Drive/` and the `logs/` directories are created by `make deploy` if missing,
so an empty volume is fine. Sizing: the whole layout is a few GB at rest, and
100 GB is comfortable — see the sizing note in
[deployment_docs/storage-architecture.md](deployment_docs/storage-architecture.md).

### config/ — the three secrets

These cannot be generated from this repository. They are what makes the volume
a working deployment rather than an empty disk.

```text
config/.env                mode 0600
config/.ssh/               mode 0755 on the directory
config/.ssh/id_rsa         mode 0644   <- deliberately readable, see below
config/.ssh/id_rsa.pub     mode 0644
config/.ssh/known_hosts    mode 0644
config/.ssh/config         mode 0644
config/slurm-config.ini    mode 0666   <- written by the admin UI at runtime
```

The modes matter and are not the SSH defaults. `biomeroworker` runs as uid 1000
and copies `.ssh/` at startup, so it cannot traverse a 0700 directory owned by
someone else; `slurm-config.ini` is rewritten from the OMERO.biomero admin UI by
the `omeroweb` container. `make deploy` sets all of these, so the simplest path
is to get the files in place and let it fix the modes.

**`.env`** — start from the committed `.env.shared`, then set the values that
are placeholders or machine-specific:

```bash
cp .env.shared $V/config/.env
chmod 600 $V/config/.env
```

```text
POSTGRES_PASSWORD           both database passwords
BIOMERO_POSTGRES_PASSWORD
OMERO_ROOT_PASSWORD         the OMERO root account
METABASE_SECRET_KEY         openssl rand -hex 32
SPIDER_USER                 your Spider account
SPIDER_PROJECT              the Spider project
OMERO_DATA_PATH             must match the mountpoint, e.g. /data/omero-data
```

The three hostname values (`OMERO_CSRF_TRUSTED_ORIGINS`, `METABASE_SITE_URL`,
`OBSERVABILITY_ROOT_URL`) are set by `make set-host`, so leave them.

**`.ssh/`** — the Spider keypair, plus `known_hosts` and `config`. This is the
one thing that cannot come from this repository, cannot be generated locally,
and has no fallback: it must be a key whose public half is already authorised on
Spider for `SPIDER_USER`. A freshly generated key produces a stack that starts
cleanly, passes most of `make doctor`, and cannot reach the cluster.

`known_hosts` needs Spider's host keys, which you can collect yourself:

```bash
ssh-keyscan spider.surf.nl >> $V/config/.ssh/known_hosts
```

`config` is written by `make deploy` from `SPIDER_USER`, so it does not have to
exist beforehand.

**`slurm-config.ini`** — rendered from the committed
`web/slurm-config-template.ini`, which substitutes `SPIDER_USER` and
`SPIDER_PROJECT` from `.env`:

```bash
./scripts/render-slurm-config.sh
```

Run this *after* linking, since it writes through the `web/slurm-config.ini`
symlink onto the volume. It needs `.env` to be readable, so the order is
`make link-config` first, then render.

### Putting it together

```bash
V=/data/omero-data
sudo mkdir -p $V/{database,database-biomero,omero,L-Drive,config,backups}

# .env
cp .env.shared $V/config/.env && chmod 600 $V/config/.env
# then edit $V/config/.env: passwords, SPIDER_USER, SPIDER_PROJECT, OMERO_DATA_PATH

# .ssh -- the authorised Spider key, from wherever your group keeps it
mkdir -p $V/config/.ssh && cp <your-key> $V/config/.ssh/id_rsa
cp <your-key>.pub $V/config/.ssh/id_rsa.pub
ssh-keyscan spider.surf.nl >> $V/config/.ssh/known_hosts
chmod 755 $V/config/.ssh && chmod 644 $V/config/.ssh/*

# link the repo at it, render the Slurm config, then deploy
make link-config
./scripts/render-slurm-config.sh
make set-host HOST=$(hostname -f)
make deploy
```

Check the key before the hour of image builds:

```bash
ssh -F .ssh/config spider 'sinfo -s | head'
```

### Starting from data rather than nothing

Populating a volume from an existing deployment or from a backup is covered in
[deployment_docs/storage-architecture.md](deployment_docs/storage-architecture.md).
Both preserve the ownership that Postgres and OMERO require, which a plain `cp`
does not — use `cp -a`.

## Day-to-Day

```bash
make up / make down        start and stop everything
make doctor                diagnose drift, changes nothing
make logs:SVC              follow one service
make link-config           re-link .env/.ssh if they go missing
```

Containers do not restart by themselves — every service is `RestartPolicy:
"no"`, so `make up` is required after any reboot, resume or volume reattach.

Full command reference: `make help`, and
[deployment_docs/deployment.md](deployment_docs/deployment.md).
