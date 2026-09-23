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

both Postgres databases                the git clone, .env, .ssh/
the OMERO image repository             Docker images
L-Drive user data                      build cache
volume-identity                        containers
backups                                logs/
                                       OpenSearch indices
```

The dividing line is whether losing it would cost data or just time. Everything
on the right is rebuilt by `make deploy` from the repository plus the volume,
except `.env` and `.ssh/`: `make init-env` writes `.env` and `make new-key`
generates the cluster key. Neither carries anything a volume needs back --
the credentials that open its databases come from the volume itself.

Three things sit deliberately on the VM despite looking like state:

- **`.env`** is per-VM: hostnames, cluster identity, generated secrets. The
  values that are fixed by a volume's data live on that volume, so a rebuilt VM
  needs a filled-in template, not a restored file.

- **`logs/`** is written by the containers and shipped to OpenSearch. It grows
  without bound. Losing it loses history, not data.

- **OpenSearch indices** are larger than everything on the volume combined, and
  derived by reindexing `logs/`. Putting them on the volume would mean most of
  the storage budget was spent preserving logs.

## What Is on the Volume

```text
/data/<volume-name>/
├── database/            OMERO Postgres          owner 999:999, mode 0700
├── database-biomero/    BIOMERO Postgres        owner 999:999, mode 0700
├── omero/               OMERO image repository  owner 1000:0,  mode 0755
├── L-Drive/             user data, /data in the containers
├── config/              volume-identity, the databases' credentials
└── backups/             nightly/: scripts/backup-nightly.sh
```

The ownership is not cosmetic. Postgres refuses to start if its data directory
is not owned by the database user and mode 0700, and OMERO expects uid 1000.
Any copy of this data must preserve it — use `cp -a`, never a plain `cp`.

### config/volume-identity

`config/` holds what belongs to the volume rather than to any VM, which is this
one file. It carries the database passwords and `METABASE_SECRET_KEY`, decided
once when the volume is empty and fixed by its data afterwards: Postgres ignores
`POSTGRES_PASSWORD` once the cluster exists, and `METABASE_SECRET_KEY` decrypts
what Metabase has already written. They open this volume and nothing else, so
losing them means losing the data. `make deploy` writes the file when it
initialises an empty volume, fills those values into a fresh `.env` from it, and
refuses to start when the two disagree.

It is mode 0600 beside the database files it opens, so it is no more exposed
than they are. `scripts/volume-identity.sh` is the only thing that writes it.

Nothing else on the volume is configuration. The rest lives in the repository,
per-VM and gitignored: `.env`, copied from `.env.example`; `.ssh/`, holding a
cluster key that is an authorisation granted on Spider rather than a property of
the data, generated with `make new-key`; and `web/slurm-config.ini`, rendered
from the committed `web/slurm-config-template.ini` by `make render-config` and
by every deploy.

## The variable that ties it together

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

# 3. this VM's settings; OMERO_DATA_PATH is read from the mount. On a volume
#    with data, then remove the values the volume supplies -- see below
make init-env

# 4. the cluster key, then register the public half it prints
make new-key

# 5. runtime config, hostname, then build and start
make init
make set-host HOST=$(hostname -f)
make deploy
```

On a volume that already holds data, delete `POSTGRES_PASSWORD`,
`BIOMERO_POSTGRES_PASSWORD` and `METABASE_SECRET_KEY` from the generated `.env`:
`make deploy` fills them from `config/volume-identity` and stops if `.env`
carries different ones. Set `OMERO_ROOT_PASSWORD`, `OMERO_IMPORTER_PASSWORD`
and `FORMS_MASTER_PASSWORD` to the volume's existing values too; those accounts
live in the OMERO database, and `volume-identity` does not record them.

`make deploy` reports which values it filled in, and stops rather than starting
a stack that cannot read its own databases.

A volume written before `volume-identity` existed carries no credentials: put
the working passwords in `.env`, `make up`, then `make adopt-volume`, which
verifies them against the running database before recording them.

What still cannot be automated from inside the VM: creating and attaching the
volume, and opening ports 4063 and 4064 for OMERO.insight. Both are portal work.
See [new-vm.md](new-vm.md).

## Populating a Volume That Is Empty

A new volume mounts as an empty directory. Three ways to fill it, depending on
what you have.

### From an existing deployment

The direct route. The stack must be down — copying a running Postgres data
directory gives you a corrupt one.

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

# volume-identity is written by the next deploy
make up && make adopt-volume
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

An empty volume is a valid starting point and needs no preparation. The
procedure is the one under [Setting Up a Fresh VM](#setting-up-a-fresh-vm)
above, unchanged: attach the volume, point `OMERO_DATA_PATH` at the mountpoint,
and deploy. The only difference is that every secret `make init-env` generated
is kept, because the volume has nothing to supply yet.

Every directory creates itself. The Postgres entrypoints chown their own data
directories on first start. `omero/` is the exception: Docker would create it
root-owned and OMERO, running as uid 1000, would die on `PermissionError:
'/OMERO/certs'`, so `deploy-local-stack.sh` creates it as 1000:1000 when it is
missing. The same script creates `L-Drive/`, `volume-identity.sh` creates
`config/`, and `backup-nightly.sh` creates `backups/nightly/`.

`make deploy` then writes `volume-identity` with the credentials it initialised
the databases with, so the volume can be opened by a later VM.

The SSH key is the one thing that cannot come from this repository or be
generated against the cluster on its own: `make new-key` produces it, but its
public half has to be authorised on Spider, or the key has to come from wherever
the group keeps it.

For test data rather than real data, `make reference-data` downloads and
verifies the reference datasets into `$OMERO_DATA_PATH/L-Drive/reference-data/`.
It needs the volume attached and the worker running, since it regenerates the
TIFFs using the worker's Python.

## Verifying

```bash
make doctor          checks the submodule, the pins, the required files, the
                     hostname, and the public URL
make ps              every container running
```

To confirm the stack is genuinely reading from the volume rather than from a
leftover directory on the boot disk:

```bash
sudo docker compose exec -T omeroserver sh -c 'touch /OMERO/.probe'
sudo ls /data/<volume-name>/omero/.probe    # must exist
sudo docker compose exec -T omeroserver rm -f /OMERO/.probe
```

And that the volume carries what opens it:

```bash
sudo test -f /data/<volume-name>/config/volume-identity && echo present
```

## Sizing

The volume is nowhere near full, and `L-Drive` dominates what it does hold:
user data is larger than the OMERO repository and both databases together.
Measure rather than assume, since this moves with every import:

```bash
sudo du -sh /data/<volume-name>/*
```

Size up only if you intend to move the OpenSearch indices onto the volume, or
expect a large influx of real imaging data.

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
  `RestartPolicy: "no"`, so a stack cannot start before its volume is mounted.
  `nl-biomero.service` starts it at boot once the volume is there; after a
  resume or a reattach later than boot, `sudo systemctl restart nl-biomero`.
