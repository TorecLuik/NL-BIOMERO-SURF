# SURF Research Cloud Catalog Item: Background and Plan

*Created 2026-09-16 · last updated 2026-09-17*

Scoping note for turning this deployment into a Research Cloud catalog item, so
that creating a workspace replaces most of `new-vm.md`.

Nothing is built yet. This records how the platform works, what a catalog item
would replace, what is still unknown, and the order to tackle it.

## Sources and How Much to Trust Them

```text
wiki     SURF service desk, "Catalog items - creation and management" (17268756)
         and "External storage volumes" (19825226), both public
specs    https://gw.live.surfresearchcloud.nl/v1/application-market/swagger/schema/
         https://gw.live.surfresearchcloud.nl/v1/workspace/swagger/schema/
code     https://gitlab.com/rsc-surf-nl/plugins — 119 public component repos
         https://gitlab.com/rsc-surf-nl/ci-cd-templates — their release pipeline
portal   screenshots of the Live "Jupyter Notebook with CUDA" item
host     the present VM, which is itself a Research Cloud workspace with two
         volumes attached — the mount convention can be read off it directly
```

The present VM is the strongest evidence, because it is the platform actually
running. The public component library is next: working playbooks rather than
documentation. The specs come third — schema is not behaviour, and field
presence does not tell us semantics.

Still unverified: no component has been created, no item assembled, and no
workspace launched from an item we authored. Treat the rest as
verified-by-reading, not verified-by-doing.

## What a Catalog Item Is

```text
component      one configuration script plus its parameters, run in a new
               workspace; versioned Development -> Pilot -> Live -> Audited
catalog item   an ordered sequence of components, plus workspace settings
workspace      the running result, a Resource that can be logged into
collection     a sub-catalog, for organising items for a collaboration
```

A catalog item is the unit of reproducible workspace creation. The payoff scales
with how often a workspace is created: for a single replacement VM, `make
provision` plus `new-vm.md` is faster. An item wins when workspaces are created
often, handed to colleagues, or when prod and dev differ only by which item was
launched.

### What it would replace

| Step in new-vm.md | Catalog equivalent | Outcome |
| --- | --- | --- |
| host packages, docker | `plugin-external-docker` (reuse) | replaced |
| nginx location block | `SRC-Nginx` (base component) | replaced |
| open 4063/4064 | catalog item access rules | replaced |
| clone, `make init` | our component | replaced |
| `make set-host` | parameter, or `hostname -f` | replaced |
| restore `.env` | parameter or secret | replaced |
| restore `.ssh/` | parameter or secret | replaced |
| `make deploy` | our component | replaced |
| restore data from backup | persistent storage volume | mostly replaced |
| — | create + attach the volume | new manual step |
| `make doctor`, `ps`, `logs`, `gpu` | — | stays |

It replaces provisioning, not operations. The Makefile's day-2 targets have no
catalog equivalent and should not have one. Both remain load-bearing.

## How Components Work

### Anatomy

A component points at a git repository, a path within it, and optionally a tag:

```yaml
ScriptSource:
  source_type: git        # the only value in the enum
  repository: string
  path:       string      # a playbook at the repo root
  tag:        string      # nullable
```

Script types are `Ansible PlayBook`, `Docker`, `Docker Compose`, `Powershell`.
One repository can host several components, each with a different `path`.

**The repository can be any git host.** The Live `Elastix` component points at
`github.com/N-Dekker/ElastixToSurfResearchCloud`, a personal GitHub account,
with no tag at all. So our playbooks can live in this repo, beside the stack
they deploy, and `tag` is optional — though we should pin it, since an unpinned
component follows the branch and can shift under a running item.

The bar for a working component is low. Elastix is 20 lines, no roles, no lint,
no CI. SURF's own repos are more elaborate than the platform demands.

### Components run as root on the host

This settles the Ansible-versus-Docker question. The `Docker Environment`
component's playbook, in full:

```yaml
- name: Install Docker and Docker Compose
  hosts: [localhost]
  gather_facts: true
  become: true
  vars:
    docker_rootless: false
  tasks:
    - name: Install Docker prerequisites
      include_tasks: tasks/docker-prerequisites.yml
```

Its tasks do `apt` installs, add Docker's GPG key and repository, and
`modprobe nf_tables`. `plugin-nginx` templates into `/etc/nginx/conf.d/`. An
Ansible component can do anything provisioning does.

Note this confirms Ansible works rather than ruling Docker out — no example of a
Docker-type component doing host-level work was found, which is weak evidence.
The question is moot in practice: Ansible demonstrably does what we need.

### Parameters

```yaml
key, label (max 30 chars), description, meta
source_type:       Fixed | Workspace | Resource | Vault | Action-Trigger
                   Component-Secret | Catalog-Item-Secret | Co-Secret
data_type:         string        # the only value — no masked/password type
required, can_be_overridden, default_value
```

Injected into playbooks as `{{ parameter_key }}`. The override chain is
`component < catalog item < workspace-user`, implemented by
`can_be_overridden`; a parameter marked Required with no value is presented to
the workspace-user interactively.

Secrecy comes from the **source type**, not a field flag. There are three
vault-backed tiers: `Component-Secret` (author-owned, e.g. licence keys),
`Catalog-Item-Secret`, and `Co-Secret` (scoped to the collaborative
organisation). Each has CRUD endpoints taking `{name, value}`.

The guard idiom for an optional parameter, from `plugin-ssh-public-key`:

```yaml
when: not((ssh_key is undefined) or (ssh_key is none) or (ssh_key | length == 0))
```

**Parameters are flat.** The portal lists every component's parameters in one
namespace, separated only by prefix convention (`co_`, `rsc_nginx_`,
`jupyter_`). Ours need an `omero_` or `biomero_` prefix to avoid collisions.

### Releases are scriptable, but we are not using that

Every SURF plugin's `.gitlab-ci.yml` includes one shared template,
`gitlab.com/rsc-surf-nl/ci-cd-templates/rsc-plugin-release`, which contains
`scripts/rsc_component_api.py` — 107 lines of stdlib Python wiring git events to
the promotion track:

```text
feature branch / MR   set-tag <branch>                          -> Development
default branch        set-tag main; promote Development         -> Pilot
git tag               set-tag <tag>; promote Dev; promote Pilot -> Live
```

Every deploy job is `when: manual`, so promotion is a human pressing a button
either way. Since we are doing the portal work by hand and iterating against a
branch, the pipeline buys little; adopt it later if the manual promote becomes
tedious.

Worth keeping from it regardless, if we ever script against the API:

- `PUT /components/{id}/` **always writes Development**. You cannot write Live
  directly; you edit Development and promote.
- Promote is `PUT .../versions/{version}/promote/` with `{"release_note": ...}`
  — PUT, not the POST the OpenAPI spec shows.
- Strip the server-owned fields before PUTting: `id`, `component_version`,
  `component_id`, `release_cycle`, `promoted_at`, `created_at`, `modified_at`,
  `status`.

**What it does not cover:** creating a component, and anything to do with
catalog items. SURF's own `test` stage says so — *"Make sure you have tested
this component in the portal before deploying. If your change affects
parameters, update them in the portal as well."* Component creation and
parameter changes are portal work even for them.

## How Catalog Items Work

From the portal view of the Live `Jupyter Notebook with CUDA` item.

### Every item starts with the same four base components

```text
#  Component            Optional  Version
1  SRC-OS                          Live
2  SRC-CO                          Live
3  SRC-Nginx                       Live
4  SRC-External plugin             Live
5  CUDA                 [ ]        Live
6  jupyter              [ ]        Live
7  Custom Packages      [x]        Development
```

The first four are the platform's base layer and are not optional; only
application components are. So our item is **four SURF base components, then
ours** — not three components of our own as first guessed.

Components can sit at mixed maturity: `Custom Packages` is on `Development`
inside a Live item.

`SRC-External plugin` is how externally hosted components get run. Its
parameters include `remote_ansible_version` (9.1.0) and `timeout` (3600
seconds), the latter a real constraint for a long deployment.

In the API this is `ApplicationPlugin`: `{order, plugin, optional}`.

### Item-level settings

```text
Workspace bootdisk size    100 GB
Workspace access button    https://==REVERSE_PROXY==
Visibility                 Public / Allowed collaborations: All
Cloud settings             per provider: OS images and machine sizes
Access rules               22, 80, 443, 3389 — in tcp 0.0.0.0/0, Mutable: No
```

- Access rules are a from-port/to-port/IP/traffic/protocol table matching the
  `update_nsgs` format in the workspace API. Each rule has a **Mutable** flag,
  decided per rule when the item is authored. Ports 4063 and 4064 are two extra
  rows; their Mutable flag is a deliberate choice.
- `==REVERSE_PROXY==` is a substitution token. For several web services in one
  item, set a location per service and give the access button a custom path
  (`https://==REVERSE_PROXY==/omero/`).
- Cloud settings pin OS images and machine sizes per provider — where GPU
  flavours are chosen, which this stack needs.

## Workspaces, Expiry, and Data

### Workspaces expire by construction

`CreateComputeApplicationSchema` requires `end_time`. `ReasonEnum` — why a
workspace action fired — includes `WORKSPACE_EXPIRED`, `LONG_PAUSED` and
`DEPLETED_WALLET` alongside `SCHEDULE` and `ADMIN`. There are schedule rules
(`action_type` + `day_of_week` + `hour`) and actions `create, delete, pause,
purge, reboot, release, resume, update, update_nsgs, update_storages, use`.

This is the most consequential fact for this deployment. OMERO data currently
lives in Docker volumes on the workspace, and an expiry, a depleted wallet or a
long pause takes the machine away.

### Storage outlives the workspace

```yaml
StorageSchema:
  end_time:  string   # "end_time is always null for Storage"
  meta:
    attached_to: [ {id, type} ]     # an array — storage knows its workspaces
  resource_meta:
    volume_id: string
```

Storage cannot have an end time (the same holds for IP and Network), so expiry
is a property of compute, not of the whole workspace family. Storage attaches
to a running workspace via
`POST /workspaces/{id}/actions/update_storages/` with `{storages: [{id, type}]}`.

So the design that survives expiry is: **OMERO data on a `Storage-Volume` with
no end time, attached to a Compute workspace that expires and is rebuilt from
the catalog item.** A rebuild stops meaning a restore from backup.

### Mounting is automatic

`SRC-OS` includes `tasks/plugin-disk-format-mount-v2.yml`, gated on an
`os_disk_format` parameter that defaults to true. It does not mount from Ansible
at all: it installs a udev-triggered systemd service (`rsc-disk-handler.service`)
plus helpers in `/opt/rsc-utilities/`, and writes `/etc/rsc/storage.json`.
Attaching a volume to a running workspace therefore mounts it automatically,
which is what makes `update_storages` usable.

```text
mount point   /data/<volume-name>     the portal volume name becomes the dir
filesystem    xfs, chmod 777, marked with a .rsc_managed file
fstab         by UUID, with nofail
fallback      /data/<number> when volume_mount_no_name is true
```

Attach a volume named `omero-data` and it appears at `/data/omero-data` across
rebuilds, with no component of ours involved. We only point the stack at it.

**This is confirmed rather than inferred.** The present VM is itself a Research
Cloud workspace — `/etc/rsc` and `/opt/rsc-utilities` are present — with two
volumes already mounted exactly as described:

```text
/dev/vdb1   100 GB   /data/storage_hpc
/dev/vdc1  1000 GB   /data/object_store_benchmark
```

So the convention below is not a prediction about how a future workspace will
behave; it is how this deployment's own machine already works.

The standalone `plugin-disk-format-mount` component is the older V1 scheme
(`/data/volume_N`) and should be ignored.

(The wiki writes the mount path as `~/data/<volume name>`. The script in
`SRC-OS` mounts at an absolute `/data/<name>`, which is what to rely on.)

**Caution:** `/mnt/scratch` is ephemeral local disk — `SRC-OS` ships a
`DATALOSS_WARNING_README.txt` saying data there is "PERMANENTLY LOST when this
instance is rebooted". `/data/<name>` is the persistent one.

### Creating and attaching a volume

From the wiki page `External storage volumes` (19825226), which is public:

```text
created     dashboard -> "Create new storage" card, a wizard; pick the cloud
            provider matching where the workspace will run
sized       chosen from storage flavours at creation; "a bigger volume will use
            more of your budget"
attached    at workspace creation, or to an existing workspace by pausing it
            and using the Storage tab (since February 2024)
exclusive   "A storage volume can only be attached to one workspace at a time"
            -- detach before reusing elsewhere
```

Three consequences for this deployment:

- **The volume is created separately, before the workspace, and is not
  declared by the catalog item.** Provisioning it is a manual dashboard step
  that stays manual. The item cannot carry it, so `new-vm.md`'s replacement
  gains one new manual prerequisite rather than losing one.
- **Provider must match.** The volume and the workspace have to be on the same
  cloud provider, which ties the storage decision to the cloud-settings choice
  in the item.
- **One workspace at a time.** Rebuilding means detach from the old workspace,
  attach to the new — not a period where both are up. Worth knowing before
  planning a migration with any overlap.

Caveat from the same page: attach/detach on a running workspace is **not
available on Oracle**. The Jupyter+CUDA item offers Oracle as a provider, so
this is a live constraint on the cloud-settings choice, not a hypothetical.

The wiki also confirms the stakes: "The local storage of any workspace you
create will be gone when you delete the workspace".

### Ordering, and the failure mode to guard against

`rsc-disk-handler.service` is `WantedBy=multi-user.target` and
`After=network-online.target`, so it mounts at **boot** — before SRC-OS's
Ansible finishes, well before any application component. Bind mounts pointed at
`/data/<name>` therefore just work: no `external: true`, no init container, no
ordering hack.

The danger is not ordering but **absence**. Attaching a volume later requires
pausing the workspace, so on a first launch the volume is either there or it is
not. If it is not, nothing fails loudly: Docker creates `/data/omero-data` as an
empty root-owned directory, OMERO initialises an empty repository on the boot
disk, and the stack comes up looking healthy on storage that dies with the
workspace.

**So the playbook must assert the mount before deploying.** This is the single
most valuable defensive check in the component:

```yaml
- name: Fail if the data volume is not mounted
  ansible.builtin.fail:
    msg: >-
      Expected {{ omero_data_path }} to be a mountpoint.
      Attach the storage volume at workspace creation.
  when: not (ansible_mounts | selectattr('mount', 'equalto', omero_data_path) | list)
```

It also covers a race: `disk_handler_rsc.sh` polls the storage API 10 times at
5-second intervals and exits 1 if it never answers, so a slow attach could boot
with no mount and no retry.

Two smaller behaviours: volume names have spaces replaced by underscores
(`tr ' ' '_'`), and `/data` is garbage-collected — the handler removes empty
directories carrying a `.rsc_managed` marker on every run, skipping mountpoints
and non-empty directories. Do not hand-create a directory there and expect it
to survive.

### One volume or three

`docker-compose.yml` has three named volumes; `omero` is mounted by four
services. A **single volume with subdirectories** is the better default, since
attach/detach is per-volume: one thing to attach, one mountpoint to assert, one
thing to forget. Splitting later is easier than merging.

The subdirectories must exist with the right ownership before containers start
— Postgres and OMERO are both particular. That is work for our component on
first boot against a fresh volume.

## Porting the Existing Scripts

Read against the actual scripts, not assumed. The earlier claim that the logic
"ports over rather than being rewritten" was optimistic — about a third needs
redesign, and one piece inverts.

### The chain is three scripts

```text
make deploy  -> bootstrap-prod.sh        preflight + smoke tests   (296 lines)
                  -> deploy-local-stack.sh   the actual work       (253 lines)
                       -> render-slurm-config.sh                    (51 lines)
make provision -> provision-vm.sh        host setup                (152 lines)
```

`bootstrap-prod.sh` is what `make deploy` runs, and is the largest of the four.

### What ports cleanly

`provision-vm.sh` **mostly disappears**, which is the best news here:

```text
apt packages, docker      -> plugin-external-docker (reused)
nginx location block      -> SRC-Nginx, or a few template tasks
make set-host             -> a parameter
docker group membership   -> irrelevant; the component runs as root
"what this cannot do"     -> preflight assertions in our playbook
```

From `deploy-local-stack.sh`, the idempotent file work translates almost line
for line into `file`, `copy` and `known_hosts` tasks: creating the log and
L-Drive directories, the `chmod`/`chown` block, `ssh-keyscan` for
spider.surf.nl, and writing `biomeroworker/10-mount-ssh.sh`.

The smoke tests in `bootstrap-prod.sh` are **already the verification
component**, near enough. Cheapest win in the whole migration.

### What does not port

**1. It is interactive.** `deploy-local-stack.sh` does
`read -r -p "Enter your Spider username"`. A component has no TTY, so this would
block until the 3600-second timeout kills it. `SPIDER_USER` and
`SPIDER_PROJECT` become parameters. Easy, but it is a behaviour change.

**2. `.env` handling inverts.** Today the scripts *mutate* `.env` in place: seed
it from `.env.shared`, append `SPIDER_USER=`, `sed -i` values into it, and
`make set-host` rewrites two files. If `.env` arrives as a parameter or secret,
that pattern is backwards — the playbook should **render** `.env` from a
template plus parameters, never patch a file handed to it. This is the largest
design consequence and it changes where `.env.shared` sits in the picture.

**3. `render-slurm-config.sh` self-bootstraps.** If the template is missing it
reverse-engineers one from an already-rendered config, `sed`-ing known Spider
values back into placeholders. On a fresh workspace there is nothing to
reverse-engineer. `web/slurm-config-template.ini` must be committed, and that
fallback branch becomes dead code in the component path.

**4. Two SSH directories, and key generation is wrong here.** The script
maintains `~/.ssh` (0600, locked down) and the project-local `.ssh/` (0644,
readable by the container), copying material between them. It also generates a
keypair when none exists — which on a catalog workspace produces a key that
Spider has never authorised, so the stack comes up unable to reach the cluster.
The key must arrive as a parameter or `Co-Secret`; generation should be dropped
from the component path.

**5. `sudo chmod -R 777`** on L-Drive and `logs/`. Fine on a VM you own; worth
reconsidering when those sit on a shared storage volume.

### Rough shape of the result

```text
~40%  translates directly     file ops, permissions, compose invocation
~30%  is removed              prompts, key generation, template bootstrapping,
                              package installs now covered by reused components
~30%  needs redesign          mainly .env: mutate-in-place -> render-from-params
```

One playbook of roughly 150–250 lines plus an `.env` template, not a thin
wrapper around the existing scripts. The scripts stay as the specification of
what the playbook has to reproduce.

## Secrets

`.env` and the Spider SSH key are the two secrets. Options, in the order they
should be considered:

```text
Co-Secret              vault-backed, scoped to the collaborative organisation.
                       Front-runner for the Spider key, which is shared by the
                       group rather than personal.
Catalog-Item-Secret    vault-backed, scoped to the item.
workspace-user param   Required with no default; the creator fills it in.
```

Either is an improvement on the current arrangement, where `.env` is a
hand-copied file that is the only copy of the deployment secrets.

**One thing to test.** The wiki says parameter values are single-line strings.
An SSH private key is ~25 lines; `.env` is multi-line. `plugin-ssh-public-key`
passes key material through a parameter, but a *public* key is one line, so the
case we care about is not demonstrated.

Cheap test once any component runs: pass a dummy multi-line value, have the
playbook write it to a file, look at the file. If newlines do not survive, use
base64 on one line and decode in the playbook — ugly but certain. Not worth
blocking on.

## What We Still Need

Roughly in the order it blocks work.

```text
1. HOW A COMPONENT IS FIRST CREATED, and by whom. SURF's tooling only updates
   and promotes components that already exist; creation appears to be portal
   work. Which portal to start in (src-dev, presumably) and what the approval
   path to Live looks like. Answerable by opening the portal.

2. WHETHER A COMPONENT AT Development CAN BE ADDED TO AN ITEM on src-dev. The
   Live Jupyter item includes one at Development, so mixed maturity is allowed
   there; whether src-dev differs is unverified. Decides whether the testbed
   loop works as planned.

3. WHETHER THE 3600s EXTERNAL-PLUGIN TIMEOUT IS ENOUGH. A full NL-BIOMERO
   deploy pulls a lot of container images. Time a cold `make deploy` first;
   the parameter is overwritable if it is too short.

4. WHETHER MULTI-LINE PARAMETER VALUES SURVIVE. See Secrets above. Testable
   as soon as we have one component running anywhere.

5. GPU AND FLAVOUR AVAILABILITY for our CO, and the storage budget. Decides
   the testbed's shape and the production volume's size.
```

**No longer needed:** an API token. The release pipeline is a convenience, and
the portal covers component creation, promotion and item assembly. Iterating
against a branch rather than a tag removes the per-change portal visit that the
pipeline would have automated.

**Answered on the present VM, which runs these components today:**

```text
restart after resume   NO. Every container reports RestartPolicy "no", and no
                       compose file sets one. The stack must be started by
                       hand after any reboot or resume -- which is also true
                       today, not a migration-specific problem.
co_passwordless_sudo   in effect here (sudo -n succeeds)
os_disk_format         in effect -- two volumes mounted at /data/<name>
volume_mount_no_name   "false", so volumes mount by name, per /etc/rsc/storage.json
```

So the base-component parameters question is mostly answered by inspection:
this workspace already runs SRC-OS and SRC-CO with settings we can read off
`/etc/rsc/storage.json` and the host's behaviour. What is left is a deliberate
choice about `co_webdav`, `co_research_drive` and `rsc_nginx_co_role`, not an
unknown.

**Answered, and not worth revisiting:** whether components can configure the
host (yes, root via Ansible), where the repo may live (anywhere), whether the
promotion track is scriptable (yes, for existing components), how access rules
work (item-level table with a per-rule Mutable flag), whether workspaces expire
(yes, and storage does not), and how volumes are created and attached (by hand
in the dashboard, one workspace at a time).

## Plan

The step-by-step procedure lives in
[catalog-item-testbed.md](catalog-item-testbed.md), which covers building and
testing the item and migrating the present VM onto attached storage.

In outline:

```text
phase 1   bind-mount change on the present VM, locally, no SURF involvement
phase 2   register a stub component, build the item on src-dev, iterate
phase 3   attach a volume to the present VM in place, then move to a workspace
          launched from the finished item
```

Two things are worth starting before any of it, because they need nothing from
SURF and inform everything else:

- **Time a cold `make deploy`**, to know whether the 3600-second
  external-plugin timeout is a real constraint.
- **Commit `web/slurm-config-template.ini`**, since the renderer's
  self-bootstrap branch cannot work on a fresh workspace.

## Relationship to the Current Machinery

Keep `new-vm.md`, `scripts/provision-vm.sh` and the Makefile while this is being
built. They are the fallback if the catalog item is delayed or rejected, they
document the sequence the item has to reproduce, and the day-2 targets survive
the migration regardless.

Retire `new-vm.md` only once a workspace has been created from the catalog item
and verified end to end.

## Component Reference

Worth reading before writing ours.

```text
plugin-os                  SRC-OS: disk handler, fail2ban, PAM, hosts
plugin-co                  SRC-CO: users, TOTP, WebDAV, iRODS, monitoring
plugin-nginx               SRC-Nginx: roles/, TLS, auth, reverse proxy
plugin-external-plugin     SRC-External plugin: runs externally hosted components
plugin-external-docker     docker + compose, rootless option
plugin-cuda                GPU host setup
plugin-cuda-conditional    conditional execution pattern
plugin-custom-packages     apt/conda/pip from a requirements file in a repo
plugin-ssh-public-key      parameter-supplied key material
plugin-ufw                 firewall rules
plugin-empty-component     the skeleton to clone
plugin-post-deployment     ordering, if something must run last
```
