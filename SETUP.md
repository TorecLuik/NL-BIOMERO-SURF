# Setting Up This Deployment

Standing up this stack on a fresh SURF Research Cloud VM.

The stack's data lives on an **attached storage volume** so it outlives the VM.
The volume also carries the values that open its own data -- the database
credentials, the OMERO root password and a few more -- so attaching it to a new
VM is enough to reach the data again.

Upstream project: [README.md](README.md). Why the storage is split this way:
[deployment_docs/storage-architecture.md](deployment_docs/storage-architecture.md).
Operating a running deployment:
[deployment_docs/runbook.md](deployment_docs/runbook.md).

## Before You Start

Three things cannot be done from inside the VM:

```text
the storage volume   created and attached in the Research Cloud portal
ports 4063 and 4064  opened in the portal, for OMERO.insight
Slurm access         the cluster key registered for SPIDER_USER on Spider
```

## Setup

```bash
# 1. confirm the volume mounted (the portal name becomes the directory name)
mount | grep /data/

# 2. clone into a directory the admins' group owns, not a personal home.
#    Ubuntu 22.04's git fails on GitHub over HTTPS with a bogus "could not read
#    Username" unless it uses HTTP/1.1; cloning over SSH instead needs the git
#    host's key in ~/.ssh/known_hosts first (ssh-keyscan -H <host>)
sudo mkdir -p /opt/omero
sudo chown root:<admin-group> /opt/omero && sudo chmod 2775 /opt/omero
sudo git config --system http.version HTTP/1.1
git clone <this repo> /opt/omero/NL-BIOMERO && cd /opt/omero/NL-BIOMERO
git config core.sharedRepository group
make provision

# 3. settings for this VM: generates every secret, reads the volume's mountpoint,
#    asks for the Spider account and project. On a volume that already holds
#    data, the values its data fixes are left unset and filled by make deploy
make init-env

# 4. the cluster key, then register the public half it prints on Spider
make new-key

# 5. submodule, runtime config, hostname values, /logs auth
make init

# 6. build and start, then smoke tests; most of the time goes to image builds
make deploy

# 7. production: start at boot once the volume is mounted, nightly backup
make install-services
```

`make init` derives everything from `.env` and the host, and every step in it is
safe to re-run. Pass `HOST=` to override the public hostname if `hostname -f` is
not the name the VM is reached by.

`make deploy` ends with smoke tests. After it, check the containers and log in
to the web UI -- smoke tests passing is not the same as the stack being usable:

```bash
make ps
```

`make doctor` diagnoses drift at any later point, and changes nothing.

## Where Each Value Lives

`.env` is the only file the stack reads. It is per-VM and gitignored;
`.env.example` documents every key and is never read at runtime.

| | Lives in | Set by |
| --- | --- | --- |
| Database credentials, `METABASE_SECRET_KEY`, OMERO root password, forms master name, Metabase admin | the volume, `config/volume-identity`, and `.env` | the first deploy onto an empty volume records them; later deploys fill `.env` from the record |
| Hostname values | `.env` | `make init` (through `make set-host`) |
| Cluster identity, other generated secrets | `.env` | `make init-env` |
| `slurm-config.ini` | `web/`, rendered | `make init` and every deploy, from `web/slurm-config-template.ini` |

The first row is fixed by the volume's data: each value is read once, when what
it protects is first created. Postgres ignores `POSTGRES_PASSWORD` once the
cluster exists, OMERO applies its root password only at database init, and
`METABASE_SECRET_KEY` decrypts what Metabase has already stored. `make deploy`
stops if `.env` carries a value that differs from the volume's record.

To change a database password later, use
`./scripts/volume-identity.sh rotate`, which changes it in the database, `.env`
and the record together; see the runbook.

## Attaching a Volume That Already Holds Data

Follow the setup steps unchanged. `make init-env` sees the volume's
`config/volume-identity` and leaves the values the data fixes unset, and
`make deploy` fills them from it.

A volume written before `volume-identity` existed carries no record. Put the
working values in `.env`, start the stack, and record them:

```bash
make up
make adopt-volume
```

This checks each value against the service that holds it before writing, so it
cannot record a wrong one. On a volume whose record predates a key, it adds
just the missing ones.

## Cluster Access

`.ssh/` holds the cluster key, plus the cluster hosts' entries the deploy
writes. It is separate from whatever key this VM uses for its git remote: the
cluster key is an authorisation granted on Spider, so it outlives the VM.

```bash
make new-key     # generate, then register the public half it prints
make show-key    # print it again
make check       # confirms Spider is reachable once it is registered
```

`make new-key` refuses to replace an existing key. `make new-key FORCE=1`
replaces it locally, which cuts this deployment off from the cluster until the
new key is registered. It does not remove the old key's authorisation: that
stays on Spider until it is removed there.

Until the key is registered, the stack runs but workflows cannot reach the
cluster.

## What Each Step Assumes

| Step | Fails if |
| --- | --- |
| `make provision` | no sudo, or no network for apt |
| `make init-env` | a `.env` already exists (it refuses to overwrite one) |
| `make init` | `NGINX_LOGS_USER` or `NGINX_LOGS_PASSWORD` unset in `.env` |
| `make deploy` | `.env` incomplete or disagreeing with the volume -- it stops before starting anything. An unreachable Spider does not stop it: the stack starts and the smoke tests report it |

`make init-env` takes the first volume mounted under `/data/` for
`OMERO_DATA_PATH`. On a VM with more than one volume attached, check that value
before deploying. Spaces in a volume name become underscores.

## If `make provision` Fails on Docker

On an image that already ships Docker CE, apt refuses to install Ubuntu's
`docker.io`:

```text
containerd.io : Conflicts: containerd
```

`make provision` detects Docker CE and keeps it. Do not resolve the conflict by
letting apt install `docker.io`: that removes Docker CE and swaps the container
runtime under a volume holding live Postgres data. To skip the package step
entirely: `./scripts/provision-vm.sh --skip-packages`.

## What a Fresh Volume Needs

Nothing. Attach it empty and deploy: every directory in it is created on first
start, with the ownership its service needs.

| Directory | Created by |
| --- | --- |
| `database/`, `database-biomero/` | the Postgres containers, which also set their ownership |
| `omero/` | `make deploy`, as uid 1000, which OMERO runs as |
| `L-Drive/` | `make deploy`; user data and workflow results |
| `config/` | `make deploy`: `volume-identity` |
| `backups/nightly/` | `scripts/backup-nightly.sh` |

**Do not pre-create these directories**, and do not chown them. `make deploy`
creates `omero/` only when it is missing; one created beforehand by root stays
root-owned, and OMERO then dies on `PermissionError: '/OMERO/certs'`.

Populating a volume from another deployment or from a backup is covered in
[deployment_docs/storage-architecture.md](deployment_docs/storage-architecture.md).
Use `cp -a`, which preserves the ownership Postgres and OMERO require.

## Day-to-Day

```bash
make ps                    status of every container
make up / make down        start and stop everything
make doctor                diagnose drift, changes nothing
make logs:SVC              follow one service
make backup                run the nightly backup now
```

Containers do not restart by themselves -- every service is
`RestartPolicy: "no"`, so none can start before the volume is mounted. With
`make install-services`, `nl-biomero.service` starts the stack at boot; without
it, `make up` after any reboot, resume or volume reattach.

Full command reference: `make help`, and
[deployment_docs/deployment.md](deployment_docs/deployment.md).
