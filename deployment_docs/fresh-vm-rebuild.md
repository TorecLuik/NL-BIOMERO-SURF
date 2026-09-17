# What a Bare-VM Rebuild Found

*Created 2026-09-17 · last updated 2026-09-17*

`make deploy` had only ever run on a host that had already run it. This is what
happened when it ran on one that had not: a Research Cloud VM with an empty
100 GB volume, no repository, no images, no nginx configuration, following
[SETUP.md](../SETUP.md) as written and changing nothing else.

It failed in eight places before the stack came up. Every one of them was
invisible on the development VM, because a repo, built images, an nginx config
and a populated volume were each quietly doing work nobody had accounted for.

## The failures, in the order they were hit

| # | Where | What happened |
| --- | --- | --- |
| 1 | `git clone` | the git host key is unknown on a new VM, so step 2 fails on "Host key verification failed" -- which reads like a credentials problem |
| 2 | `make provision` | died before printing its own report, on an unguarded `grep` over a `.env` that does not exist yet. `make: *** Error 2` and nothing else |
| 3 | `make new-key` | produced a key comment shaped like an email, which Spider's registration form rejects. The documented step could not be completed |
| 4 | `make deploy` | preflight blocked on `.ssh/config` "missing" -- a file the deploy writes itself a few seconds later |
| 5 | `make deploy` | `.ssh-worker/` owned by root, so the unprivileged copy into it failed |
| 6 | `make deploy` | nothing created `${OMERO_DATA_PATH}/omero`, so Docker made it root-owned and all three OMERO containers died on `PermissionError: '/OMERO/certs'` |
| 7 | `make deploy` | the Metabase database step waited 60s for Postgres, which is not enough while `initdb` runs on an empty volume -- and then continued into a certain failure instead of stopping |
| 8 | `make deploy` | the worker's gid was scraped with `tr -cd '0-9'` across compose's progress output, yielding a 600-digit "group" that `chgrp` rejected |

Then, with the stack up, two more that only a fresh set of credentials reaches:

| # | Where | What happened |
| --- | --- | --- |
| 9 | the importer | `OMERO_IMPORTER_USER` ships as `root`, so its password *is* root's password -- but `.env.example` presents them as two secrets. Two different values, and the importer could not log in: it retried for five minutes, exited, and nothing restarted it. Ten containers up, all smoke tests green, imports silently discarded |
| 10 | the importer | its first start created the tables and died before stamping Alembic, after which every start replayed the migrations against a schema already at head and could not recover |

## Why none of this showed up before

Each failure needs some piece of state to be *absent*, and on a machine that
has deployed once, none of them are:

```text
.ssh/config, .ssh-worker/, omero/     created by an earlier deploy
built images                          compose prints nothing extra, so the gid scrape works
a populated volume                    Postgres starts in seconds, not minutes
a working .env                        its credentials already agree
```

The same shape applies to three defects that were not fatal but made the tools
lie: `doctor` and `fetch-reference-data.sh` addressed containers as
`nl-biomero-*`, a name compose derives from the *project directory*. In a
checkout named anything else, those lookups quietly returned nothing, and the
failure of the lookup was reported as a fact about the deployment ("importer
image not built yet", "cannot read the metabase database", "biomeroworker is
not running"). All three were false.

## What changed as a result

Fixes are one commit each on `prod-rebuild-2026-09`. Beyond them:

- **`make init-env`** writes `.env`, generating the ten secrets that are only
  entropy and asking for the two that mean something outside the VM. Twelve
  `CHANGE ME` blanks was the step most likely to be got wrong, and one of the
  ways to get it wrong -- #9 above -- fails silently.
- **The GPU fallbacks are gone.** `BIOMERO_GPU_PARTITION` and
  `BIOMERO_GPU_GRES` could never apply: every GPU workflow pins its own. They
  also carried a trap, since a workflow setting only `_job_gpus` inherited the
  global `--gres` and emitted both, which Spider rejects. Confirmed by
  comparing `make gpu` with the values set, emptied and deleted.
- **`BIOMERO_SLURM_CONFIG_FILE`** makes the deployment read the config it
  renders, rather than merging a search path that begins with a `localslurm`
  file baked into the worker image.

## What it proves

The second rebuild, against the fixed tree, reached a running stack with all
smoke tests passing, and then all nine checks in
[pipeline-tests.md](pipeline-tests.md) passed on it -- including I2 and I3,
which had never been run. B3 measured **56 nuclei**, the same number the
development VM recorded.

That last number is the point. The same input through an independently built
stack, with different credentials on a volume that started empty, produces the
same measurement.

## The second rebuild

Run against the fixed tree, from the same starting point: empty volume, no
repository, no images, no nginx configuration.

```text
make provision    full report, no early exit
make init-env     one command; 10 secrets generated, OMERO_DATA_PATH read from
                  the mount, root and importer passwords in step
make new-key      comment Spider's form accepts
make init         no [FAIL]; the remaining warnings are all correct pre-deploy
make deploy       exit 0, all smoke tests passed
```

Then, with nothing done by hand in between: reference data fetched and verified
against its checksums, both images imported through the Importer panel, and A1
run to a nucleus mask back in OMERO. The importer came up saying READY TO UPLOAD
DATA TO OMERO on its first start, and `/logs` answered 401 without credentials
and 302 with them.

## Still not covered

```text
OMERO.insight on 4063/4064        needs the ports opened in the portal
the Research Cloud catalog item   see catalog-item-migration.md
```

Three registered workflows (`stardist5d`, `spotcounting`,
`aggregates_measurements`) still have no test, for lack of suitable reference
data rather than lack of procedure; see [reference-data.md](reference-data.md).
