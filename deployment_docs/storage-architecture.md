# Storage Architecture

*Created 2026-09-17 · last updated 2026-09-17*

Every piece of state this deployment must not lose lives on an attached storage
volume, not on the VM. The VM holds the repository, the Docker images and the
running containers, all of which can be rebuilt. This describes the split, what
is on the volume, and how to populate a volume that does not have it yet.

The reason for the split is that a SURF Research Cloud workspace expires.
Storage does not: `end_time` is always null for a Storage resource. So a
workspace can be rebuilt, or replaced by one launched from a catalog item,
without a restore-from-backup cycle.

## The Split

```text
ATTACHED VOLUME                        THE VM
state, irreplaceable                   compute, rebuildable

both Postgres databases                the git clone
the OMERO image repository             Docker images (~34 GB)
L-Drive user data                      build cache (~9 GB)
.env, .ssh/, slurm-config.ini          containers
backups                                logs/
                                       OpenSearch and Loki indices
```

The dividing line is whether losing it would cost data or just time. Everything
on the right is reconstructed by `make deploy` from the repository plus the
volume.

Two things sit deliberately on the VM despite looking like state:

- **`logs/`** is written by the containers and shipped to OpenSearch. It is
  ~780 MB and grows. Losing it loses history, not data.
- **OpenSearch indices** are ~7 GB — larger than everything on the volume
  combined, and derived by reindexing `logs/`. Putting them on the volume would
  mean most of the storage budget was spent preserving logs.

## What Is on the Volume

```text
/data/<volume-name>/
├── database/            OMERO Postgres          owner 999:999, mode 0700
├── database-biomero/    BIOMERO Postgres        owner 999:999, mode 0700
├── omero/               OMERO image repository  owner 1000:0,  mode 0755
├── L-Drive/             user data, /data in the containers
├── config/              the secrets -- see below
└── backups/             backup_master.sh output
```

The ownership is not cosmetic. Postgres refuses to start if its data directory
is not owned by the database user and mode 0700, and OMERO expects uid 1000.
Any copy of this data must preserve it — use `cp -a`, never a plain `cp`.

### config/ and the symlinks

`config/` holds the three files that are gitignored and therefore absent from a
fresh clone:

```text
config/.env                the stack's configuration and all its passwords
config/.ssh/               the Spider key, its public half, config, known_hosts
config/slurm-config.ini    rendered Slurm configuration
```

The repository reaches them through symlinks, created by `make link-config`:

```text
.env                  -> /data/<volume-name>/config/.env
.ssh                  -> /data/<volume-name>/config/.ssh
web/slurm-config.ini  -> /data/<volume-name>/config/slurm-config.ini
```

The direction is worth being explicit about, because it reads backwards: the
**repository holds the links, the volume holds the files**. Detach the volume
and all three vanish from the clone. That is the intended behaviour — it means
the repository carries no secrets and the volume is the single source of truth.

`.env` is the one that must be a symlink rather than a copy. Docker Compose
only auto-loads `.env` from the project directory and this repository's
Makefile passes no `--env-file`, so the link is what lets the volume own the
configuration without changing every compose invocation.

### Permissions on config/.ssh

`config/.ssh` is mode 0755 with the private key at 0644, which is not what SSH
would normally accept. It is deliberate: `biomeroworker` runs as uid 1000 and
copies the directory at startup, and it cannot traverse a 0700 directory owned
by someone else. `scripts/deploy-local-stack.sh` sets exactly these modes, with
the comment *"keep the project SSH copy readable for Docker and host SSH locked
down for manual use"*.

The consequence is that a readable private key now travels on a volume that
moves between machines. The host's own `~/.ssh` stays 0600. If this matters for
your threat model, the fix is to have the deploy path copy the key from a
vault-backed secret to a 0600 location at start time rather than storing it
readable — see the catalog item plan.

## How the Stack Finds It

One variable, `OMERO_DATA_PATH`, set in `.env`:

```yaml
- "${OMERO_DATA_PATH:?OMERO_DATA_PATH must be set}/database:/var/lib/postgresql/data"
- "${OMERO_DATA_PATH:?OMERO_DATA_PATH must be set}/omero:/OMERO"
- "${OMERO_DATA_PATH:?OMERO_DATA_PATH must be set}/L-Drive:/data"
```

`docker-compose.yml` declares no named volumes. Every mount is a bind mount
under `$OMERO_DATA_PATH`.

The `:?` guard matters more than it looks. Without it, an unset variable would
expand to an empty string, Docker would create the directories, and OMERO would
initialise an empty repository on the boot disk — a stack that comes up looking
healthy on storage that dies with the VM. With the guard, compose refuses to
start.

The guard does not catch the case where `OMERO_DATA_PATH` is set but the volume
is *not mounted*, because the path still exists as an empty directory. A
playbook deploying this should assert the mountpoint before starting anything:

```yaml
- name: Fail if the data volume is not mounted
  ansible.builtin.fail:
    msg: "Expected {{ omero_data_path }} to be a mountpoint."
  when: not (ansible_mounts | selectattr('mount', 'equalto', omero_data_path) | list)
```

### Mounting is automatic

On Research Cloud, `SRC-OS` installs a udev-triggered systemd unit,
`rsc-disk-handler.service`, which formats and mounts attached volumes at boot.
A volume named `omero-data` appears at `/data/omero-data`, XFS, chmod 777, with
an fstab entry by UUID and `nofail`. Nothing in this repository mounts anything.

```text
mount point   /data/<volume-name>     spaces in the name become underscores
fallback      /data/<number>          when volume_mount_no_name is true
```

`/data` is garbage-collected: the handler removes empty directories carrying a
`.rsc_managed` marker. It only looks one level deep (`-maxdepth 1`), skips
mountpoints, and skips anything non-empty, so subdirectories on the volume are
safe. Do not hand-create a directory directly under `/data` and expect it to
survive.

`/mnt/scratch` is ephemeral local disk and its contents are lost on reboot.

## Setting Up a Fresh VM

With a volume that already has the layout:

```bash
# 1. attach the volume in the Research Cloud portal, then confirm it mounted
mount | grep /data/

# 2. clone and prepare the host
git clone <repo> && cd NL-BIOMERO
make provision

# 3. point OMERO_DATA_PATH at the mount
#    .env arrives with the volume in step 4, so edit .env.example here, or
#    export it, if the volume name differs from the committed default
grep OMERO_DATA_PATH .env.example

# 4. link the repo at the volume's secrets
make link-config

# 5. this VM's hostname differs from the one baked into .env
make set-host HOST=$(hostname -f)

# 6. build and start
make deploy
```

`make init` runs `link-config` for you, so in practice steps 4 and 6 collapse
into `make init && make deploy`.

Step 5 is easy to forget and the failure is confusing. `.env` travels with the
volume, so it carries the *previous* machine's hostname in
`OMERO_CSRF_TRUSTED_ORIGINS`, `METABASE_SITE_URL` and `OBSERVABILITY_ROOT_URL`.
The stack starts, but the web UI rejects logins with a CSRF error. `make doctor`
checks all three against `hostname -f` and reports the mismatch.

What still cannot be automated from inside the VM: creating and attaching the
volume, and opening ports 4063 and 4064 for OMERO.insight. Both are portal work.
See [new-vm.md](new-vm.md).

## Populating a Volume That Is Empty

A new volume mounts as an empty directory. Three ways to fill it, depending on
what you have.

### From an existing deployment

The direct route, and the one used to create the current layout. The stack must
be down — copying a running Postgres data directory gives you a corrupt one.

```bash
make down

V=/data/<volume-name>
sudo mkdir -p $V/{database,database-biomero,omero,L-Drive,config,backups}

# Docker named volumes live under /var/lib/docker/volumes/<name>/_data.
# -a preserves the ownership and modes that Postgres and OMERO require.
for v in database database-biomero omero; do
  sudo cp -a /var/lib/docker/volumes/nl-biomero_$v/_data/. $V/$v/
done
sudo cp -a web/L-Drive/. $V/L-Drive/

# the secrets
sudo cp -a .env $V/config/.env
sudo cp -a .ssh $V/config/.ssh
sudo cp -a web/slurm-config.ini $V/config/slurm-config.ini
sudo chmod 755 $V/config/.ssh
sudo chmod 644 $V/config/.ssh/*

make link-config && make up
```

Verify ownership landed correctly before starting — this is the step that most
often goes wrong:

```bash
sudo stat -c '%n %u:%g %a' $V/database $V/database-biomero $V/omero
# expect  database 999:999 700   database-biomero 999:999 700   omero 1000:0 755
```

### From a backup

`backup_and_restore/` writes one timestamped set across both databases, the
server data and Metabase. Both sides understand folder targets as well as
Docker volumes, which is what a bind-mounted layout needs — `backup_server.sh`
takes `--omero-folder <path>` to read straight from the host directory, and
`restore_server.sh` takes `--targetPath <path>` to extract into one. The
restore workflow is the same shape as above: stack down, restore into the
directories, bring it up.

Note that `restore_server.sh` refuses to extract into a directory that already
exists, so restoring over a populated `omero/` means moving it aside first.

Read the scripts before depending on them for a production cutover — their
README describes them as "examples for inspiration, not prescriptive
recommendations".

### From nothing — a genuinely fresh deployment

An empty volume is a valid starting point. Create the six directories and let
the stack initialise:

```bash
V=/data/<volume-name>
sudo mkdir -p $V/{database,database-biomero,omero,L-Drive,config,backups}
```

Postgres initialises `database/` and `database-biomero/` on first start, and
OMERO creates its repository under `omero/`. Leave those three empty and owned
by root — the containers set them up. The directories that need populating are
`config/` and, if you want the test datasets, `L-Drive/`.

`config/` cannot be generated, because it is the secrets:

```text
.env                seed from .env.example, then set the real passwords, the
                    Spider username, and the hostname via make set-host
.ssh/               the Spider keypair. It must be a key Spider has already
                    authorised -- a generated one will not work, and the stack
                    comes up unable to reach the cluster
slurm-config.ini    rendered from web/slurm-config-template.ini, which is
                    committed
```

The SSH key is the one thing that cannot come from this repository or be
generated locally. It has to come from wherever the group keeps it, or be
newly authorised on Spider.

For test data rather than real data, `make reference-data` downloads and
verifies the reference datasets into `$OMERO_DATA_PATH/L-Drive/reference-data/`.
It needs the volume attached and the worker running, since it regenerates the
TIFFs using the worker's Python.

## Verifying

```bash
make doctor          checks the symlinks resolve, the pins agree, the hostname
                     matches, and the public URL answers
make ps              every container running
```

To confirm the stack is genuinely reading from the volume rather than from a
leftover directory on the boot disk:

```bash
sudo docker compose exec -T omeroserver sh -c 'touch /OMERO/.probe'
sudo ls /data/<volume-name>/omero/.probe    # must exist
sudo docker compose exec -T omeroserver rm -f /OMERO/.probe
```

And that the secrets really live on the volume, not in the clone:

```bash
ls -la .env .ssh web/slurm-config.ini    # all three must be symlinks
```

## Sizing

The current deployment uses 4.5 GB of a 100 GB volume:

```text
L-Drive             3.0 GB      the largest item by far
omero                569 MB
database             128 MB
database-biomero     106 MB
config                24 KB
```

100 GB leaves room for roughly twenty times the current image data. Size up
only if you intend to move the OpenSearch indices onto the volume, or expect a
large influx of real imaging data.

Note that the volume is not what constrains this deployment today. The boot
disk is, and Docker images plus build cache are the reason — `docker system
prune` typically reclaims more than this entire volume holds.

## Constraints Worth Knowing

- **A volume attaches to one workspace at a time.** Migrating means detach from
  the old, attach to the new; there is no overlap window. Copy to a second
  volume first if you need both up at once.
- **Attach and detach require pausing the workspace**, and are not supported at
  all on Oracle.
- **The volume and the workspace must be on the same cloud provider.**
- **Containers do not restart by themselves.** Every service has
  `RestartPolicy: "no"`, so `make up` is required after any reboot, resume or
  reattach.
