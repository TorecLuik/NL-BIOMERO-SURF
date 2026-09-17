# Setting Up This Deployment

Standing up this stack on a fresh SURF Research Cloud VM.

The stack's data lives on an **attached storage volume** so it outlives the VM.
The volume also carries the credentials that open its own databases, so
attaching one to a new VM is enough to reach the data again.

Upstream project: [README.md](README.md). Why the storage is split this way:
[deployment_docs/storage-architecture.md](deployment_docs/storage-architecture.md).

## Before You Start

Three things cannot be created from inside the VM:

```text
the storage volume   attached in the Research Cloud portal
ports 4063 and 4064  opened in the portal, for OMERO.insight
Slurm access         the cluster key registered for SPIDER_USER
```

## Setup

```bash
# 1. confirm the volume mounted (the portal name becomes the directory name)
mount | grep /data/

# 2. clone and prepare the host
git clone <this repo> && cd NL-BIOMERO
make provision

# 3. settings for this VM
cp .env.example .env
#    then fill in every value marked CHANGE ME, and set OMERO_DATA_PATH to the
#    mountpoint from step 1. On a volume that already holds data, leave the
#    database passwords as they are: make deploy takes those from the volume.

# 4. the cluster key, then register the public half it prints
make new-key

# 5. submodules and runtime config
make init

# 6. public hostname
make set-host HOST=$(hostname -f)

# 7. build and start -- about an hour, most of it image builds
make deploy
```

Then verify:

```bash
make doctor      # config drift, hostname, pins, public URL
make ps          # every container running
```

and log in to the web UI. `make doctor` passing is not the same as the stack
being usable.

## Where Each Value Lives

`.env` is the only file the stack reads. It is per-VM and gitignored; `.env.example`
documents every key and is never read at runtime.

| | Lives in | Set by |
| --- | --- | --- |
| Database passwords, `METABASE_SECRET_KEY` | the volume, `config/volume-identity` | the first deploy onto an empty volume |
| Hostnames | `.env` | `make set-host` |
| Cluster identity, generated secrets | `.env` | you, from `.env.example` |
| `slurm-config.ini` | the volume | the OMERO.biomero admin UI |

The first row is fixed by the volume's data: Postgres ignores
`POSTGRES_PASSWORD` once the cluster exists, and `METABASE_SECRET_KEY` decrypts
what Metabase has already stored. `make deploy` fills those into a fresh `.env`
from the volume, and stops if `.env` carries a different value.

## Attaching a Volume That Already Holds Data

Follow the setup steps. At step 3, leave the database passwords and
`METABASE_SECRET_KEY` as `CHANGE ME` — `make deploy` takes them from the volume.

A volume written before `volume-identity` existed carries no credentials. Put
the working passwords in `.env`, start the databases, and record them:

```bash
make up
make adopt-volume
```

This verifies the password against the running database before writing, so it
cannot record a wrong one.

## Cluster Access

`.ssh/` holds the cluster key and nothing else. It is separate from whatever key
this VM uses for its git remote: the cluster key is an authorisation granted on
Spider, so it outlives the VM and is revoked deliberately.

```bash
make new-key     # generate, then register the public half it prints
make show-key    # print it again
```

`make new-key` refuses to replace an existing key; `make new-key FORCE=1`
overrides, which revokes the access the old key was granted.

Until the key is registered, the stack runs but cannot reach the cluster.

## What Each Step Assumes

| Step | Fails if |
| --- | --- |
| `make provision` | no sudo, or no network for apt |
| `make init` | volume not attached, or no `config/` on it |
| `make deploy` | `.env` incomplete, disagrees with the volume, or Spider unreachable |

If `make init` cannot find `config/`, check `mount | grep /data/` first: the
volume is usually either not attached or mounted under a different name than
`OMERO_DATA_PATH` expects. Spaces in a volume name become underscores.

## If `make provision` Fails on Docker

On an image that already ships Docker CE, apt refuses to install Ubuntu's
`docker.io`:

```text
containerd.io : Conflicts: containerd
```

`make provision` detects this and keeps the existing Docker. On an older
checkout, skip the package step instead:

```bash
./scripts/provision-vm.sh --skip-packages
sudo apt-get install -y apache2-utils     # not part of the conflict
```

Do not resolve it by letting apt install `docker.io`: that removes Docker CE and
swaps the container runtime under a volume holding live Postgres data.

## What a Fresh Volume Needs

An empty volume needs only its directory layout. Everything in it is created by
the containers on first start.

```bash
V=/data/omero-data          # the portal volume name becomes the directory name
sudo mkdir -p $V/{database,database-biomero,omero,L-Drive,config,backups}
```

| Directory | Filled by |
| --- | --- |
| `database/`, `database-biomero/` | Postgres, on first start |
| `omero/` | OMERO, on first start |
| `L-Drive/` | user data; `make deploy` creates it |
| `config/` | `make deploy`: `volume-identity` and `slurm-config.ini` |
| `backups/` | `backup_master.sh` |

Do not pre-create anything inside the data directories or chown them: Postgres
runs `initdb` as uid 999 mode 0700, and OMERO builds its repository tree as uid
1000. A few GB at rest; 100 GB is comfortable.

Populating a volume from a backup is covered in
[deployment_docs/storage-architecture.md](deployment_docs/storage-architecture.md).
Use `cp -a`, which preserves the ownership Postgres and OMERO require.

## Day-to-Day

```bash
make up / make down        start and stop everything
make doctor                diagnose drift, changes nothing
make logs:SVC              follow one service
```

Containers do not restart by themselves — every service is `RestartPolicy: "no"`,
so `make up` is required after any reboot, resume or volume reattach.

Full command reference: `make help`, and
[deployment_docs/deployment.md](deployment_docs/deployment.md).
