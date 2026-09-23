# Proposal: A Production Path for NL-BIOMERO

*Created 2026-09-23 · last updated 2026-09-23*

For the NL-BIOMERO maintainers, from SURF.

SURF rebuilt its NL-BIOMERO deployment for production on a SURF Research Cloud
VM with an attached storage volume. The work is on branch `prod-rebuild` of
`github.com/slawa-loev/NL-BIOMERO`, branched from `master` at `a9f45807`. This
document proposes bringing its generic parts upstream, as a series of small
pull requests that leave the existing quick start as it is.

It is about how the deployment repository is put together. Defects in the
individual components (BIOMERO, BIOMERO.importer, OMERO.biomero) are listed
separately in [upstream-suggestions.md](upstream-suggestions.md), and cited
here only where they bear on a proposal.

Everything below was checked against upstream `master` at `5f1f08c`
(2026-09-23).

## Summary

NL-BIOMERO's defaults are geared to trying it out: a committed `.env` with
preset values, named volumes, a Metabase database file and test images in the
repository. The README describes that setup as intended for demonstration and
development. Each of those choices is also a trap in production, and a
production operator has to find and undo them one by one.

The proposal is to leave those defaults alone and add an explicit production
path next to them, built on six principles:

1. **The current defaults stay as they are.** Production is added as a
   separate, opt-in layer -- an override file and a setup step that replace the
   defaults on the hosts that use it -- rather than by changing the defaults
   that existing installs and evaluations rely on.
2. **Irreplaceable state has one declared home, and the stack checks it is
   the right one before starting.** The databases, the image repository, the
   user data and the credentials that open them sit under a single configured
   location -- a local directory, an attached volume or network storage -- so
   they can be backed up, moved or restored as one unit. Before starting, the
   stack confirms that location holds the data it expects, and stops if it
   finds an empty or unfamiliar one instead of initialising a fresh one.
3. **No secret is committed; every secret is generated at install time.** The
   few values that are set once when the data is first created and cannot
   change afterwards -- the database passwords, the OMERO root password, the
   Metabase keys -- are stored with the data, so a new host picks them up
   rather than generating new ones that would lock it out.
4. **Anything configured by hand is kept in the repository and applied
   automatically.** The Slurm configuration is rendered from a template and the
   Metabase dashboards are rebuilt from exported definitions, so a fresh
   install needs no manual steps in either.
5. **Only the web server and OMERO.insight are reachable from outside.** Every
   other service listens on the host alone.
6. **Every deploy is checked**: before it starts, that the configuration is
   complete and matches the data; afterwards, that each service actually
   works.

All of it runs in production today.

## What Production Runs Into Today

On current `master`:

| | What `master` does | What it costs in production |
| --- | --- | --- |
| Secrets | `.env` and `.env.shared` are tracked, with preset values marked "placeholder, change me" | Nothing forces the change, and nothing detects that it was skipped |
| Ports | OMERO.web, Metabase, OpenSearch and OpenSearch Dashboards publish on all interfaces; OpenSearch runs with security disabled | On a host without a firewall they are reachable directly, bypassing the web server and the `/logs` authentication. A Research Cloud VM has no host firewall; only the portal's network rules stand in between |
| Storage | Databases in named volumes; OMERO repository and user data configurable (`OMERO_DATA_PATH`, `INPLACE_STORAGE_HOST_PATH`), defaulting to a named volume and `./web/L-Drive` in the checkout | By default state is spread over Docker's storage and the working tree; an unset or unmounted path is not caught |
| Metabase | H2 file, tracked in git, dashboard ids hardcoded in `.env` | A single file on a bind mount; dashboards exist only where someone clicked them together |
| Restart | No restart policy, no boot mechanism | Nothing comes back after a reboot, and adding one naively is unsafe (below) |
| Logs | Five of fourteen services cap their logs; the databases, Metabase and the log stack do not | The uncapped ones grow without bound |
| Backup | `backup_and_restore/`, described as "examples for inspiration" | No tested path, and in-place imports are not covered (below) |
| Checks | None before or after deploy | Failures surface later, often somewhere else |

Concrete cases from this rebuild:

- Deploying onto a VM that had never run the stack failed in eight separate
  places, each of them hidden on a machine that had deployed before.
- Metabase's H2 store, left with an empty directory where it expects its file,
  retried a lock forever and filled the disk at about 2.5 GB a day while still
  answering HTTP 200.
- With the importer's password set to a different value from root's -- they
  are the same account when `OMERO_IMPORTER_USER=root` -- the importer retried
  for five minutes and exited. Every smoke test was green; imports were
  silently discarded.

## Proposals

File references are to the
`prod-rebuild` branch.

### P1. Bind backend ports to loopback

Publish OMERO.web (4080), Metabase (3000), OpenSearch (9200, 9300, 9600) and
OpenSearch Dashboards (5601) on `127.0.0.1` only. The web server is the public
entry point and reaches them locally; containers reach each other over the
compose network. The OMERO.insight ports stay public.

The branch changes `docker-compose.yml` and `opensearch-compose.yml`, one line
per port. Browsing a backend directly then needs an SSH tunnel, so the demo
might keep today's binding and production use loopback -- but loopback is the
safer default for both.

### P2. Cap container log growth

A shared `logging-defaults.yml` (json-file, size-capped), pulled into every
service with `extends:`. `master` already caps five services inline; this covers
the other nine and gives one place to change it. The branch's `make doctor` flags
any running container without a cap.

### P3. Metabase on Postgres, dashboards as code

Run Metabase's application database as a `metabase` database on the existing
BIOMERO Postgres instead of an H2 file. That removes the H2 failure mode, puts
the dashboards inside a database that is already backed up, and takes an 84 MB
binary out of the repository (the test images under `web/L-Drive` add another
165 MB, which a production checkout does not need either).

Dashboards then become code: `scripts/export-metabase-dashboards.sh` writes
them to `metabase/dashboards.json` with everything per-install translated to
names -- databases, tables, fields, filter targets -- and no credentials.
`scripts/restore-metabase-dashboards.sh` rebuilds them on any install against
its own schema, enables embedding, and writes the ids it used back into `.env`.
`make deploy` runs the restore, so a fresh install has working dashboards with
no manual steps. The upstream Metabase documentation's manual steps (re-point
the databases, regenerate the embedding key, fix the click-through URLs)
become unnecessary.

Two details matter for anyone reimplementing this: filters wired to
query-builder cards target field ids too, and must travel by name like the
queries; and the export should default to the dashboard ids `.env` embeds,
since a restore replaces ids.

### P4. A production override: data root, required secrets, generated `.env`

Three changes that together make production explicit:

- **One data root.** `master` already makes the OMERO repository and the user
  data configurable. Production goes one step further: every stateful mount,
  the databases included, is a bind mount under `${OMERO_DATA_PATH:?}` --
  `database/`, `database-biomero/`, `omero/`, `L-Drive/` and `config/`. The
  `:?` makes compose refuse to start when it is unset, rather than creating
  empty directories on the boot disk.
- **Required secrets.** Every secret uses `${VAR:?}` in compose, so a missing
  one stops the deploy instead of reaching Postgres as an empty password.
- **Generated `.env`.** `scripts/init-env.sh` writes `.env` from `.env.example`,
  generating every value that is only randomness and asking for the two that
  mean something outside the host (the cluster account and project). The
  importer's password is derived from root's when it logs in as root.

This could be a `docker-compose.prod.yml` override plus an `init-env` step, so
the current defaults stay untouched for anyone not using the override.

### P5. Keep the values the data depends on with the data

**The problem.** A few settings take effect only once, when what they protect
is first created:

```text
Postgres passwords                 when the database cluster is initialised
OMERO root password (ROOTPASS)     at omego db init
METABASE_SECRET_KEY, admin login   at Metabase's first setup
forms master's name                when OMERO.web creates that account
```

After that, the data keeps the original values, and changing them in `.env`
has no effect on it. So when a host is replaced and `.env` is written afresh,
the new values no longer match what the data expects: the stack starts, then
services fail to log in, with errors that do not name the cause.

**What the branch does**, with `scripts/volume-identity.sh`, at each point in
the data's life:

- **When the data is first created** -- the first deploy onto an empty data
  location -- the values used are written to
  `<data root>/config/volume-identity`, next to the data.
- **When a new host takes over existing data** -- `init-env` leaves those values
  out of the new `.env`, and `make deploy` copies them from the record. If `.env`
  holds a different value, the deploy stops before anything starts.
- **When the data predates the record** -- `make adopt-volume` writes one, after
  checking each value against the service that holds it: a database login, an
  OMERO login, a Metabase login.
- **When a password has to change** -- `volume-identity.sh rotate` changes it in
  the database, in `.env` and in the record together.

Two lessons from building it: a `psql` from inside the Postgres container
proves nothing about a password, because the image's local rules are `trust`;
and `omero login` joins a saved session without checking the password given,
so a probe needs an empty `OMERO_SESSIONDIR` or `-C`.

### P6. Preflight, smoke tests and a drift checker

`scripts/bootstrap-prod.sh`, behind `make deploy`:

- **Before:** tools and disk space, every key in `.env.example` set and not a
  placeholder, credentials agreeing with the volume, the importer's password
  agreeing with root's, cluster reachability.
- **After:** every service running, both databases and Metabase's answering,
  the web login page, installed versions against the pins, the runtime patches
  present, the log pipeline actually indexing, the public URL.

`make doctor` checks for drift at any time and changes nothing: submodule
against its pin, installed against pinned versions, hostname values, the
embedded dashboard ids, container log caps. Most of what this rebuild found was
found by these two.

### P7. A supported backup that covers what in-place imports need

The importer always links (item 3), so the OMERO repository holds symlinks into
the user data. A backup of the repository alone therefore keeps links, not
pixels. A supported backup has to either include the user data or say plainly
that it is part of the data.

`scripts/backup-nightly.sh` takes custom-format dumps of the three databases
from the running containers, archives the OMERO repository and the secrets, and
checksums the set. Restoring into a scratch database was tested. The
branch leaves user data to the storage layer; upstream might offer both.

### P8. One source of truth for configuration the UI edits

The OMERO.biomero admin UI writes `slurm-config.ini` and `biomero-config.json`,
which a deployment also renders or tracks in git. Either the UI's edits are
lost on the next deploy, or the working tree drifts. Authoritative-file mode,
already on `master`, settles which file is *read*; it does not settle which
*wins*.

The branch renders `web/slurm-config-template.ini` on every deploy and treats UI
edits as transient. The better long-term answer is layered: the committed
template as base, and the UI writing an override file kept with the data.

### P9. Check the data before starting, and restart safely

Postgres and OMERO initialise whatever empty location they are given, and the
stack then looks healthy. That happens on any kind of deployment:

- **Named volumes:** Compose names them after the checkout directory, so a
  checkout that is renamed or re-cloned under another name gets new, empty
  volumes, while the real data sits unused in the old ones.
- **A mistyped or unset data path:** Docker creates the directory, empty.
- **Attached storage that has not mounted yet**, typically at boot.

The last is why automatic restart is unsafe today: with `restart: always`,
Docker can start Postgres before the storage is there. The branch therefore
keeps `RestartPolicy: "no"` and starts the stack from a systemd unit gated on
the mount (`scripts/install-host-services.sh`) -- which covers only that one
case, and only on this host.

A portable answer for upstream covers all three: a one-shot init service that
exits non-zero unless the data location holds a sentinel written when the data
was first created (the volume identity of P5 can serve), with every stateful
service depending on it. That also makes `restart: unless-stopped` safe,
without anything host-specific.

## Suggested Sequence

Smallest and most independent first:

| PR | Content | Depends on |
| --- | --- | --- |
| 1 | P1 loopback ports | -- |
| 2 | P2 log caps | -- |
| 3 | P3 Metabase on Postgres, with a migration note for existing H2 installs | -- |
| 4 | P3 dashboard export and restore, `metabase/dashboards.json` | 3 |
| 5 | P4 production override and `init-env` | -- |
| 6 | P5 volume identity | 5 |
| 7 | P6 preflight, smoke tests, `doctor` | 5 |
| 8 | P7 backup | 5 |
| 9 | P9 data check before start, and restart policy | 6 |

P8 is a design question for OMERO.biomero rather than a pull request here.

The branch cannot go upstream as one merge: it sits on a June base, and `master`
has since moved to the 2.9 pre-releases while the branch runs the 2.8.2
releases with two targeted patches. Each pull request above would be rebased
onto current `master`.

## What Stays Deployment-Specific

Not proposed: the SURF Research Cloud provisioning (`scripts/provision-vm.sh`),
the host nginx location block, the Spider cluster configuration and GPU
policy, the systemd units, and the operator runbook. They are specific to this
host and cluster, though they show what a site layer on top of the generic
parts looks like.

## Already on `master`

No action needed:

- **Authoritative-file Slurm configuration** (`BIOMERO_SLURM_CONFIG_FILE`),
  added 2026-07-29.
- **The worker's SSH copy no longer nests on restart.** It still mounts a
  whole directory (`SSH_HOST_PATH`, default `~/.ssh`); see
  [upstream-suggestions.md](upstream-suggestions.md) item 6.
- **Job output verification.** BIOMERO's `job_template.sh` now sets
  `set -eo pipefail` and fails a job that produces no output, which the branch
  had patched in.
- **The importer submodule URL** points at `NL-BioImaging/BIOMERO.importer`.
