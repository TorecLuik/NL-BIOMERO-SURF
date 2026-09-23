# Verification Pitfalls

Probes on this stack that report success whatever the truth is. Each one has
produced a false claim here. The general rule: **a check is only worth trusting
once it has been seen to fail** -- run it once with a value that must be
rejected (a wrong password, a user that does not exist) before believing its
"yes".

## A password checked from inside Postgres

The official Postgres image's `pg_hba.conf` trusts `local` and `127.0.0.1`
connections. So both of these succeed with any password, or none:

```bash
sudo docker compose exec -T database psql -U omero -d omero -c 'select 1'
sudo docker compose exec -T -e PGPASSWORD=wrong database psql -h 127.0.0.1 -U omero -c 'select 1'
```

Only a connection from another address reaches the `scram-sha-256` rule --
which is how the other containers connect. Probe from a throwaway container on
the compose network, as `scripts/volume-identity.sh` does in
`password_authenticates`:

```bash
sudo docker run --rm --network <net> -e PGPASSWORD="$P" postgres:16 \
  psql -h <container-ip> -U omero -d omero -c 'select 1'
```

The same trust is why `compose exec ... psql` is fine for queries and useless
as proof that a rotated password took.

## `omero login` reuses a saved session

If a session for the same user and server is stored locally, `omero login`
joins it and never checks the password given:

```text
omero login -s localhost -u root -w wrong     "Using session for root@localhost:4064", exit 0
```

Probe with an empty session directory (`OMERO_SESSIONDIR=$(mktemp -d)`) or
`omero login -C`. `omero logout` takes no `-q`; do not let its exit status stand
in for the login's.

## `pgrep -f` over SSH finds itself

```bash
ssh host 'pgrep -f bootstrap-prod.sh'    # always matches: the bash -c line contains the text
```

A wait loop built on it never ends. Use a pattern the probe's own command line
cannot match, e.g. `pgrep -f '[b]ootstrap-prod.sh'`: the regex matches
`bootstrap-prod.sh` but the command line holds `[b]ootstrap-prod.sh`. That only
holds while nothing else in the same command line spells the name out plainly
-- a second check or a `grep bootstrap-prod.sh` in the same `ssh` call brings
the self-match back.

## Root-only directories from a non-root shell

The backup directories are `0700 root`. From a non-root shell:

- a glob such as `ls $DIR/*` does not expand, so the command runs on the
  literal pattern and fails -- or, inside `$(...)`, yields nothing and the
  next command runs somewhere else entirely;
- `[[ -s $DIR/file ]]` is false for a file that exists and is full.

Expand and test as root: `sudo sh -c 'ls -d /path/*'`, `sudo test -s ...`.

## Grepping config for names

Registered workflows are `name_repo = url`, with spaces, and names may contain
hyphens (`fractal-cellpose-sam-biaflows`). `grep -E '^[a-z0-9_]+_repo='` misses
both and makes registered workflows look unregistered:

```bash
grep -E '^[a-z0-9_-]+_repo *=' web/slurm-config.ini
```

## Printing values while checking them

Filters such as `grep -viE 'pass|secret'` miss secrets embedded in other values
-- a database URL carries its password. Compare values without printing them
(`[ "$a" = "$b" ] && echo same`), or print the key names only.
