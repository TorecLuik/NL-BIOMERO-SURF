# Deploying to a New VM

End-to-end checklist for a fresh SURF Research Cloud VM. Steps 1-4 are manual
because they need credentials or root; step 5 is the automated part.

Budget about an hour, most of it image builds.

## 1. Host prerequisites

Nothing in this repository installs these, and `make deploy` refuses to run
without them.

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-plugin git make apache2-utils
sudo systemctl enable --now docker
```

Requirements:

```text
disk    40 GB free on /, at least 25 GB to build at all
memory  16 GB
docker  needs sudo; every make target already uses it
```

## 2. Clone and fetch the submodule

```bash
sudo mkdir -p /opt/omero && sudo chown "$USER" /opt/omero
cd /opt/omero
git clone <repo-url> NL-BIOMERO
cd NL-BIOMERO
make init
```

`make init` fetches the `biomero-importer` submodule and then runs `make doctor`.
The importer image builds from that submodule, so the build fails on an empty
directory without it.

## 3. Restore the secrets

These cannot be regenerated. Copy them from your archive:

```text
.env            deployment secrets; the only copy
.ssh/id_rsa     Spider key, plus id_rsa.pub, known_hosts and config
```

```bash
chmod 600 .env .ssh/id_rsa
chmod 644 .ssh/id_rsa.pub .ssh/known_hosts .ssh/config
```

The public key must already be authorised on Spider for `SPIDER_USER`. Confirm
before going further:

```bash
ssh -F .ssh/config spider 'sinfo -s | head'
```

## 4. Point the deployment at this host

Three values are per-VM. A wrong CSRF origin lets the whole stack start and
then blocks OMERO.web login with an error that does not name the cause.

```bash
make set-host HOST=$(hostname -f)
```

That rewrites `OMERO_CSRF_TRUSTED_ORIGINS`, `METABASE_SITE_URL` and
`OBSERVABILITY_ROOT_URL` in `.env` and `.env.shared`. `make doctor` warns
whenever they stop matching the host.

## 5. Deploy

```bash
make deploy
```

Preflight, build, start, then smoke tests: services running, both databases
answering, web login page, installed versions against the pins, the runtime
patch, Spider reachability, the log stack, and the public URL.

## 6. Publish through host nginx

SURF owns the TLS server block; this repository only supplies the location
block.

```bash
sudo cp nginx/omero-web.conf /etc/nginx/app-location-conf.d/omero-web.conf
sudo htpasswd -c /etc/nginx/.htpasswd <admin-user>   # guards /logs
sudo nginx -t && sudo systemctl reload nginx
```

Without this the stack runs but is unreachable from outside the VM. `make
doctor` reports whether the public URL answers.

## 7. Restore data, if this replaces an existing deployment

Volumes, the Metabase H2 database and stack configs come from the backup. The
restore commands are in its `MANIFEST.md`:

```text
/data/storage_hpc/biomero-backup-2026-09-15/
```

Restore with the stack stopped (`make down`), then `make up`.

## 8. Verify what the smoke tests cannot

These need real data or a browser:

```text
run a CPU workflow, a MIG GPU workflow, and deconvolve_plate on full A100
confirm workflow results import back into OMERO
drop files under /data and confirm the importer picks them up
open OMERO.web and check the Metabase dashboards embed
open /logs and confirm the log viewer renders behind basic auth
connect OMERO.insight on 4063/4064
```

## Spider

Nothing needs creating there. `/project/<project>/Share/biomero/` already holds
`data/`, `slurm-scripts/` and `singularity_images/`, and BIOMERO regenerates job
scripts and pulls missing container images on demand.

## If something is wrong

```bash
make doctor   # submodule, pins, images, hostname, public URL
make ps       # all containers, log stack included
make logs:SVC # follow one service
```
