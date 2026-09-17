# Catalog Item: Testbed and Migration Procedure

*Created 2026-09-16 · last updated 2026-09-17*

How to build and test the catalog item, and how to migrate the present VM onto
attached storage once it works.

Companion to [catalog-item-migration.md](catalog-item-migration.md), which
records how the platform works and why. This document is the operational half:
what to do, in what order, on which machine.

**Status: proposal.** No workspace has been created from a catalog item we
authored, and the sizing and composition below are inferred from one Live SURF
item plus the public component sources. Expect the first real launch to correct
parts of this. Nothing here should be followed literally without checking it
against the portal in front of you.

## Three Machines, Three Phases

The plan involves three distinct things, and conflating them causes confusion.

```text
A  PRESENT VM     exists, has the real data, built by hand via new-vm.md.
                  IT IS ITSELF A RESEARCH CLOUD WORKSPACE -- /etc/rsc and
                  /opt/rsc-utilities are present and two volumes are already
                  attached. So it can take another attached volume.
                  -> phase 1: bind-mount change, done locally

B  TESTING VM     does not exist yet; a workspace launched from a catalog item
                  on src-dev, with all components and an attached volume
                  starts empty, no real data
                  -> phase 2: build and debug the component here

C  PRODUCTION     the eventual replacement for A: a workspace from the finished
                  item, with real data on an attached volume
                  -> phase 3: the migration
```

**A is a Research Cloud workspace.** Confirmed on the machine:

```text
/etc/rsc, /opt/rsc-utilities        present -- SRC-OS ran here
/dev/vdb1  100 GB  1.3 GB used      /data/storage_hpc
/dev/vdc1 1000 GB  176 GB used      /data/object_store_benchmark
/dev/vda1   97 GB   75 GB used 77%  /  (boot disk)
```

This matters more than anything else in this document. The mount convention
described in the migration doc is not a prediction — it is already running on
this machine, with two volumes mounted at `/data/<name>` exactly as documented.
And A can be paused and given a third volume without being rebuilt.

Phase 1 happens on A and needs nothing from SURF. Phase 2 happens on B and
touches A not at all. Phase 3 either upgrades A in place or replaces it with C.

Note that "pause" throughout phase 3 means **pausing the workspace** in the
portal, not stopping the Docker stack. The machine goes away: SSH sessions
drop, and anything you need to read during the procedure must be written down
beforehand.

The reason phase 1 comes first: the component's job is deploying a stack whose
data lives at `/data/<name>`. Until `docker-compose.yml` works that way, there
is nothing coherent for the playbook to deploy. Doing it on A first means
debugging the compose change against real data on a machine you can roll back,
before it becomes one step inside a component you are also debugging.

## Phase 1 — Bind-Mount Change on the Present VM

Local work on A. No storage volume, no catalog machinery, no SURF involvement.

`docker-compose.yml` has three named volumes: `database`,
`database-biomero`, and `omero` (the last mounted by four services). Move all
three under a single directory, so the layout matches what an attached volume
will look like later.

```yaml
# before
- "database:/var/lib/postgresql/data"
- "omero:/OMERO"

# after
- "/data/omero-data/database:/var/lib/postgresql/data"
- "/data/omero-data/omero:/OMERO"
```

On A, `/data/omero-data` is just a directory you create. On B and C it will be
the mountpoint of an attached volume, and nothing in the compose file has to
change between them. That is the point of doing it this way.

```bash
sudo mkdir -p /data/omero-data
# then move existing volume contents into place — see below
```

Steps:

1. **Back up first.** `./backup_and_restore/backup/backup_master.sh` — this is
   the rollback, and phase 1 moves live database files.
2. `make down`.
3. Move the contents of the three Docker volumes into
   `/data/omero-data/{database,database-biomero,omero}`. The volumes are at
   `/var/lib/docker/volumes/nl-biomero_<name>/_data`.
4. Fix ownership. Postgres and OMERO are both particular; get this wrong and
   containers fail to start. Check what the current volumes use before moving.
5. Edit `docker-compose.yml`, `make up`, verify.
6. Keep the old Docker volumes until you are satisfied. They are the fast
   rollback; the backup is the slow one.

Verify with `make doctor`, `make ps`, and a real login to the web UI — not just
that containers are running.

## Phase 2 — The Testbed

A workspace on `src-dev`, built from the same components the real item will use.
Resist building a bare VM and configuring it by hand: that tests a
configuration you will never ship.

### Register the component first

The item cannot list a component that does not exist, so the component is
created before the item — even though its playbook is not written yet.

A stub is enough to register. The Live `Elastix` component is 20 lines, so the
bar is low:

```yaml
- hosts: localhost
  gather_facts: false
  become: true
  tasks:
    - name: Placeholder
      ansible.builtin.debug:
        msg: "nl-biomero component registered"
```

Push that to a branch in this repository, then create the component in the
portal pointing at **the branch, not a tag**. That is what makes iteration
bearable later: pushing updates the component with no portal visit. Pin to a
tag only when promoting toward Live.

### Item composition

```text
#  Component              Source            Optional   Why
1  SRC-OS                 base              no         disk handler, host setup
2  SRC-CO                 base              no         users, sudo, WebDAV
3  SRC-Nginx              base              no         reverse proxy
4  SRC-External plugin    base              no         runs externally hosted
5  Docker Environment     reuse             no         docker + compose
6  CUDA                   reuse             yes        untick until the rest works
7  nl-biomero             ours              yes        untick on the first launch
```

Marking ours and CUDA **optional** is the key trick. Launch with both unticked
and you get a working base workspace in minutes; iterate on the component
separately. Without it, every failed playbook means a full workspace rebuild.

### Storage: two volumes

```text
omero-data     sized for real data plus growth; the one that matters
scratch-test   small, disposable, for destructive first attempts
```

A volume attaches to **one workspace at a time**, which is exactly what bites
during development: if your test workspace holds `omero-data` and you want a
clean second workspace, you must pause and detach first. A throwaway volume
lets you rebuild freely.

Name both **without spaces** — the mount script applies `tr ' ' '_'`, so
`omero data` becomes `/data/omero_data`.

### Flavour and provider

```text
GPU        no, not at first. plugin-cuda is a reused component you are not
           debugging, and GPU flavours are scarcer and dearer. Add at the end.
size       ~8 core / 32 GB, 100 GB boot disk — matches the Jupyter+CUDA item
           and builds the images comfortably
OS         Ubuntu 22.04, what the SURF components are tested against
provider   NOT Oracle — attach/detach on a running workspace is unsupported
           there, and that is the loop you need
```

Unknown and worth checking before committing: which providers and flavours your
CO actually has access to, and what the budget allows.

### Sequence

```text
1. push the stub playbook to a branch
2. portal: register the `nl-biomero` component -> that branch
3. portal: create both storage volumes
4. portal: build the item, all seven components, 6 and 7 optional and unticked
5. launch a workspace with omero-data attached
6. verify: /data/omero-data is mounted, nginx answers, access rules are right
7. tick ours on, iterate by pushing to the branch
```

Step 6 is worth doing on its own. It proves the platform behaves as expected
before any of our code is involved — if the mount is not there, you learn it in
ten minutes rather than inside a failing playbook.

### The iteration loop

```text
push to branch  ->  relaunch workspace (or re-run the component)
broke it        ->  rebuild the workspace; the volume reattaches, data survives
```

Open question for the portal: whether a component at `Development` can be added
to an item on `src-dev`. The Live Jupyter item includes `Custom Packages` at
`Development`, so mixed maturity is allowed there; whether `src-dev` differs is
unverified.

## Phase 3 — Migrating the Present VM

Rewritten once it was established that A is itself a Research Cloud workspace
with volumes already attached. That makes the in-place route real, and much
cheaper than a rebuild.

### The data is smaller than expected

```text
nl-biomero_database           126 MB
nl-biomero_database-biomero    66 MB
nl-biomero_omero              564 MB
                              -------
                              ~760 MB
```

Under a gigabyte. The existing backup on `/data/storage_hpc` agrees: the whole
set tars to about 540 MB.

This changes the shape of the problem. Moving this data is a `cp` of a few
hundred megabytes, not a bulk transfer — a minute or two, not an outage to
schedule around. Everything below gets easier as a result.

(The four observability volumes — `grafana-data`, `loki-data`,
`opensearch-data`, `opensearch-dashboards-data`, plus `fluent-bit-db` — are
separate and were not measured. Decide whether they move too, or are treated as
rebuildable.)

### The boot disk is the actual problem

```text
/dev/vda1   97 GB   75 GB used   77%   /
```

The boot disk is 77% full, and everything in `/var/lib/docker` — images, build
cache, containers, and today's volumes — is on it. That is a live operational
risk independent of any catalog work. Moving the data volumes off it helps a
little; moving Docker's image and build storage would help far more.

Worth checking what is actually consuming those 75 GB before deciding how much
of it phase 3 should fix.

### Route 2 — attach a volume to A, in place (recommended first)

A is a workspace, so it can be paused and given a third volume. It keeps its
identity, hostname, SSH keys, `.env`, and everything else. No restore cycle, no
DNS change, no rebuild.

```text
BEFORE THE PAUSE
  1. backup_master.sh, and verify the output. This is the rollback.
  2. write this procedure down somewhere not on this machine -- the pause
     drops all SSH sessions, so anything you need to read must be elsewhere.
  3. create the volume in the portal (e.g. omero-data, no spaces in the name)
  4. make down, so the stack stops cleanly rather than being frozen

THE PAUSE
  5. portal: pause the workspace
  6. portal: Storage tab, attach the new volume
  7. portal: resume

AFTER RESUME
  8. verify the mount: mount | grep /data/omero-data
  9. cp -a the three volume directories into /data/omero-data/
 10. fix ownership to match what the old volumes used
 11. edit docker-compose.yml to the bind-mount paths (phase 1)
 12. make up, then make doctor, make ps, and a real login
 13. keep the old Docker volumes until satisfied
```

Steps 9 to 12 are phase 1, just performed after the volume exists rather than
against a plain directory. If phase 1 has already been done against
`/data/omero-data` as a local directory, this becomes: attach the volume, move
the directory's contents onto it, restart.

**The stack will not come back by itself.** Confirmed on the present VM: every
container reports `RestartPolicy: "no"`, and no compose file sets one. Step 12
is therefore mandatory, not a fallback.

This is already true of every reboot, not just this migration — worth deciding
separately whether `restart: unless-stopped` belongs in the compose file. If it
is added, do it before the pause so the resume is the first test of it.

### Route 1 — new workspace from the finished item

The eventual target, and what proves the catalog item works. Worth doing after
route 2 rather than instead of it: once the data is on a detachable volume,
route 1 becomes much simpler, because the volume moves rather than the data.

```text
BEFORE THE WINDOW
  1. phases 1 and 2 complete; the item launches a working stack
  2. dry run: launch a workspace from the item with a COPY of the data on a
     scratch volume, restore, verify. This rehearses the whole thing while A
     is still serving users.
  3. write down the hostname change and who makes it
  4. agree the rollback: A stays paused but intact until C is verified

THE WINDOW
  5. announce downtime
  6. on A: make down, then a final backup_master.sh
  7. pause A, detach omero-data
  8. launch C from the item with omero-data attached
  9. verify: make doctor, make smoke, a real login
 10. repoint the hostname at C

AFTER
 11. leave A paused but intact for an agreed period
 12. retire A only once C has run unattended through a normal week
```

Step 7 is where the one-workspace-per-volume rule bites: the volume cannot be
attached to both, so there is no overlap window. Detach from A, attach to C.
The alternative is copying to a second volume beforehand, which removes the
constraint at the cost of duplicating the data — cheap at this size, and worth
it for the safety.

### What we still do not know

```text
- how long a pause/resume cycle actually takes, which sets the outage length
- whether the observability volumes move too, or are rebuilt
- how the hostname moves in route 1: whether C can take A's name, or whether
  OMERO config and OMERO_CSRF_TRUSTED_ORIGINS need rewriting. make set-host
  rewrites OMERO_CSRF_TRUSTED_ORIGINS, METABASE_SITE_URL and
  OBSERVABILITY_ROOT_URL, so a changed hostname touches more than DNS.
- whether Spider needs anything re-authorised for a new machine
- what is filling the 75 GB boot disk, and whether phase 3 should address it
```

## Backup and Restore Tooling

Already in the repository and mature enough to build on:

```text
backup_and_restore/backup/backup_master.sh    one timestamp across OMERO DB,
                                              BIOMERO DB, server data, Metabase
backup_and_restore/restore/restore_db.sh      database restore
                                              (plus _metabase and server paths)
```

The Metabase pair writes and reads a `.pg_dump` since Metabase moved off H2;
the older `.tar.gz` archives are folder backups of the H2 store and restore
down a separate path in the same script. Both were re-tested on 2026-09-17.

Useful for phase 3: both sides support **folder targets as well as Docker
volumes** (`--omero-folder`), which is exactly what a bind-mounted layout
needs. The README's own restore workflow is `docker-compose down`, restore,
bring up — the same shape as the window above.

Its README opens by saying the scripts are "examples for inspiration, not
prescriptive recommendations", so review them against the current stack before
depending on them for a production cutover.
