# Open Items

Work in progress on `prod-rebuild-2026-09`. Delete entries as they close, and
delete this file when it is empty. For how the deployment is configured, see
[deployment.md](deployment.md).

## Blocking

**Archive the secret files.** They exist only on this VM and are in no backup:

```text
.env         deployment secrets; there is no .env.secrets, so this is the only copy
.env.keys    dotenvx private keys
.ssh/        Spider SSH key material
```

Losing `.env` means reconstructing every secret by hand. Archive all three,
encrypted, off this VM. Nothing else should be treated as done until this is.

The automated snapshot was refused by a credential-safety guard, so this has to
be done by hand.

## Not Yet Verified

Everything below needs real data, a browser, or a fresh machine, so none of it
is covered by the automated smoke tests:

```text
end-to-end workflow run with results imported back into OMERO
BIOMERO importer picking up files under /data
Metabase dashboard embedding in OMERO.web
OMERO.insight connectivity on 4063/4064
scripts/bootstrap-prod.sh on a genuinely bare VM
```

The last one matters most. The script's whole purpose is working where nothing
is set up yet, and it has only ever run here, where Docker, the repo and the
secrets already existed.

## Then

Provision the replacement prod VM, run `scripts/bootstrap-prod.sh` on it from a
bare state, work through the list above, and merge `prod-rebuild-2026-09`.

## Rollback

```bash
git checkout prod-known-good-2026-09-15   # a8b76d3c
```

Restore commands are in `/data/storage_hpc/biomero-backup-2026-09-15/MANIFEST.md`.
That backup holds both Postgres volumes, the OMERO data volume, the Metabase H2
database and stack configs. It does not hold the secret files above.

## Current State

Verified on the dev VM against live Spider:

```text
worker   biomero 2.8.2, biomero-importer 1.4.2
web      omero-biomero 1.6.1, biomero 2.8.2, omero-forms 2.3.1, omero-web 5.33.1
stack    all 8 services up; databases, web login and Spider reachability pass
slurm    scripts generated from descriptors; no local job scripts
gpu      cellpose and deconvolve_plate on full A100, everything else CPU-only,
         no workflow emits --gres and --gpus together
jobs     full-A100, MIG and CPU-only probe jobs all COMPLETED on Spider
```
