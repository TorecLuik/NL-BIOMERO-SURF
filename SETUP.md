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

The volume carries `.env` and `.ssh/`, so the last one is usually already
satisfied — the key comes with the volume.

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

Either rename the volume in the portal, or set the path before step 3:

```bash
echo 'OMERO_DATA_PATH=/data/<volume-name>' >> .env.shared
```

Note that spaces in a volume name become underscores in the mount path.

## What Each Step Assumes

| Step | Fails if |
| --- | --- |
| `make provision` | no sudo, or no network for apt |
| `make init` | volume not attached, or no `config/` on it |
| `make set-host` | — |
| `make deploy` | preflight finds missing secrets, or Spider unreachable |

`make init` is the one that most often stops people, and it is almost always
the volume: either not attached, attached under a different name, or attached
but empty. Check `mount | grep /data/` first.

## A Fresh Volume, With No Data

An empty volume is a valid starting point, but it needs its directories and its
secrets before `make init` will work:

```bash
V=/data/omero-data
sudo mkdir -p $V/{database,database-biomero,omero,L-Drive,config,backups}
```

Leave the three data directories empty — Postgres and OMERO initialise them on
first start. `config/` is the part you have to fill:

```text
.env                seed from .env.shared, then set real passwords and
                    SPIDER_USER; make set-host fixes the hostname
.ssh/               the Spider keypair, mode 0755 on the directory and 0644 on
                    the files, so the worker container can read them
slurm-config.ini    rendered from the committed web/slurm-config-template.ini
```

The SSH key is the one thing that cannot be generated locally or taken from
this repository — it has to be a key Spider has already authorised. A generated
key gives you a stack that starts cleanly and cannot reach the cluster.

Populating a volume from an existing deployment or from a backup is covered in
[deployment_docs/storage-architecture.md](deployment_docs/storage-architecture.md).

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
