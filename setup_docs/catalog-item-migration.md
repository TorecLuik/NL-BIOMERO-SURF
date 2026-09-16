# SURF Research Cloud Catalog Item: Background and Plan

*Created 2026-09-16 · last updated 2026-09-16*

Scoping note for turning this deployment into a Research Cloud catalog item, so
that creating a workspace replaces most of `new-vm.md`.

Nothing here is built yet. This records what the platform offers, what it would
replace, the open questions, and the order to tackle them.

Sources are the SURF service desk wiki, `Catalog items - creation and
management` (page 17268756) and its subpages. Statements below that come from
that documentation are marked; everything else is inference from how this
deployment works and should be treated as untested.

## What a Catalog Item Is

From the documentation:

```text
component      one configuration script, run inside a new workspace, plus its
               parameters; versioned Development -> Pilot -> Live -> Audited
catalog item   an ordered sequence of components, plus workspace settings
workspace      the running result; "an actual Resource that can be logged into"
collection     a sub-catalog, for organising items for a collaboration
```

A catalog item is the unit of reproducible workspace creation. It is aimed at
power users packaging an environment that a group launches repeatedly.

The payoff therefore scales with how often a workspace is created. For a single
replacement VM, `make provision` plus the manual steps in `new-vm.md` is
probably faster. A catalog item wins when workspaces are created often, handed
to colleagues, or when prod and dev should differ only by which item was
launched.

## What It Would Replace

| Step in new-vm.md | Catalog equivalent | Outcome |
| --- | --- | --- |
| host packages, docker | component | replaced |
| clone, `make init` | component | replaced |
| `make set-host` | parameter, or derived from `hostname -f` | replaced |
| nginx location block | component | replaced |
| open 4063/4064 | catalog item access rules | replaced |
| restore `.env` | parameter supplied at workspace creation | replaced |
| restore `.ssh/` | parameter supplied at workspace creation | replaced |
| `make deploy` | component | replaced |
| restore data from backup | — | stays manual |
| `make doctor`, `ps`, `logs`, `gpu` | — | stays |

It replaces provisioning, not operations. The Makefile's day-2 targets have no
catalog equivalent and should not have one; `make doctor` is still what you run
against a workspace that is already up. The two do not overlap, so both remain
load-bearing.

## Secrets

The documented parameter override order is:

```text
component < catalog item < workspace-user
```

A parameter marked Required with no value supplied by the catalog item "will be
presented to the workspace-user to be filled in interactively". That is the
mechanism for user-scoped secrets: the Spider SSH key and `.env` are supplied by
whoever creates the workspace, never baked into a shared item.

Component Secrets are a different feature and the wrong tool here. They are
vault-backed values resolvable only by the component itself, intended for
author-owned things like license keys. A per-user cluster key is not that.

This is a genuine improvement over the current arrangement, where `.env` is a
hand-copied file that is the only copy of the deployment secrets.

## Ansible or Docker

The documentation lists four script types: Ansible Playbook ("usually used in
Research Cloud to configure Linux workspaces"), PowerShell, Docker ("the
component just wraps a dockerfile") and Docker Compose ("wraps a docker-compose
configuration"). It does not compare them and states no limitations for the
Docker types.

Recommendation: **Ansible**, despite this stack being Docker-based.

Reasoning, which is inference rather than documented:

- Almost all of this work is host-level: apt packages, the docker daemon, nginx
  config under `/etc/nginx/`, file permissions, SSH material, a git submodule.
  Docker components provision containers, not hosts.
- Parameter injection is documented for Ansible as `{{ parameter_key }}` and for
  PowerShell as an environment variable. No Docker equivalent is shown.
- The stack already has `docker-compose.yml` as its application definition. A
  Compose component would duplicate or compete with it.

The clean split is an Ansible component that prepares the host and then invokes
the existing Compose stack, which is what `scripts/deploy-local-stack.sh`
already does. The logic ports over rather than being rewritten.

Worth testing before committing: whether a Docker Compose component can do
host-level work such as writing nginx configuration at all.

## Open Questions

Resolve these before designing components.

```text
1. Is there a masked or password parameter source type? The "Using parameters"
   page references "Secrets and workspace info: special parameter source types"
   but that page was not found; the URL needs tracking down. A multi-line secret
   such as an SSH private key may also hit the documented constraint that
   parameter values are single-line strings with no quotes.

2. Can a Docker or Docker Compose component configure the host, or is it
   confined to containers? This decides whether the Ansible recommendation is
   merely preferable or actually required.

3. Are there existing SURF components to read as examples? Public GitHub
   searches found none, so this plan rests on documentation alone and the first
   real component will probably correct parts of it.

4. Are workspaces expected to be long-lived or ephemeral? The documentation does
   not say. It matters here because OMERO data lives in Docker volumes on the
   workspace, which interacts with the backup and restore step.

5. How do access rules interact with an existing workspace? Ports 4063 and 4064
   are set in the catalog item; whether changing them affects already-running
   workspaces is unclear.
```

## Plan

1. Answer the open questions above, particularly 1 and 2, since they constrain
   the design.
2. Decide the component split. A reasonable starting guess is three:
   host preparation, stack deployment, verification.
3. Map every step of `new-vm.md` onto a component or parameter, and write down
   what stays manual.
4. Decide how `.env` is supplied: one blob parameter, or several typed ones.
   Depends on question 1.
5. Write the playbooks, reusing `scripts/provision-vm.sh`, which already
   encodes the host-preparation logic.
6. Launch a workspace from the item. This is the real validation, and it finally
   exercises the bare-VM path that has never been run end to end.

## Relationship to the Current Machinery

Keep `new-vm.md`, `scripts/provision-vm.sh` and the Makefile while this is being
built. They are the fallback if the catalog item is delayed or rejected, they
document the sequence the item has to reproduce, and the day-2 targets survive
the migration regardless.

Retire `new-vm.md` only once a workspace has been created from the catalog item
and verified end to end.
