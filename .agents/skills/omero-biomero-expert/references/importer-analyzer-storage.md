# Importer and Analyzer Storage

## Shared Storage Invariant

For in-place import and analyzer-to-importer result import, these containers must see the same storage at the same path:

```text
biomeroworker   -> /data
biomero-importer -> /data
omeroserver     -> /data
omeroweb        -> /data for UI file selection/config
```

The compose mount is usually:

```yaml
- "./web/L-Drive:/data"
```

If paths differ between containers, imports can queue correctly but fail with file-not-found, broken symlink, or result import polling failures.

## Analyzer to Importer Flow

When `IMPORTER_ENABLED=true`, analyzer results use `SLURM_Import_Results.py` instead of the classic `SLURM_Get_Results.py` API path.

Result storage layout:

```text
<group_base_path>/
└── .analyzed/
    └── <workflow-uuid>/
        └── <YYYYMMDD_HHMMSS>/
            ├── <job_id>_out.zip
            ├── <job_id>_out/
            │   └── data/out/
            ├── metadata.csv
            └── omero-<job_id>.log
```

The worker creates an upload order in the BIOMERO.importer tracking DB and polls until import succeeds or fails. Imported images then receive workflow metadata annotations.

## Group Base Path Resolution

The group base path is resolved in this order:

1. explicit mapping in `web/biomero-config.json`
2. fallback `<base_dir>/<group_name>`, where `base_dir` comes from importer `settings.yml`

The active OMERO group at workflow launch determines where analysis results land.

## Permissions

The `biomeroworker` process must be able to write to the group base path. For first-time groups, it must also be able to create the group-named subfolder under `base_dir`.

The default compose stack runs the worker as the OMERO server user, commonly uid `999`. Host/NAS permissions must allow that UID to create:

```text
/data/<group>/
/data/<group>/.analyzed/
```

The importer user must have read/write access to `/data`, and OMERO.server must also mount `/data` to resolve symlink-based in-place imports.

## Importer Configuration

Important env/config:

```text
INGEST_TRACKING_DB_URL      # same DB for web, worker, importer
IMPORTER_ENABLED=true       # needed on biomeroworker, not just web/importer
SQLALCHEMY_URL              # BIOMERO event-sourcing DB
config/biomero-importer/settings.yml
web/biomero-config.json
```

The worker requires:

```yaml
- "./config/biomero-importer:/opt/omero/server/config-importer:ro"
- "./web/biomero-config.json:/opt/omero/server/biomero-config.json:ro"
```

Verify the worker library:

```bash
sudo docker compose exec biomeroworker \
  /opt/omero/server/venv3/bin/python -c "import biomero_importer; print('ok')"
```

Verify DB URLs align:

```bash
sudo docker compose exec -T biomeroworker env | grep INGEST_TRACKING_DB_URL
sudo docker compose exec -T biomero-importer env | grep INGEST_TRACKING_DB_URL
sudo docker compose exec -T omeroweb env | grep INGEST_TRACKING_DB_URL
```

Mask passwords in user-facing output.

## BIOMERO.importer Model

BIOMERO.importer:

- stores orders in the BIOMERO Postgres DB
- imports files in-place from `/data`, always with `--transfer=ln_s`. This is
  hardcoded in `biomero_importer/utils/importer.py` -- keyword defaults on
  `import_to_omero` and `import_dataset` plus literals at both call sites -- so
  no setting changes it. The managed repository holds symlinks, not pixels: move
  or delete a source file and its image is permanently unreadable, and a backup
  that does not dereference archives the dangling link. Use OMERO.insight for
  anything that must outlive its source. See `permissions-and-deployment.md`,
  "The Importer Always Links, Never Copies".
- uses `/OMERO` and `/data` shared with OMERO.server
- authenticates to OMERO as root initially, then switches context to the requesting user/group
- writes preprocessing outputs under `.processed`
- registers a `.zarr` by external reference (`com.glencoesoftware.ngff:multiscales`)
  rather than copying or linking, so such images have no fileset and no pixels
  path by design; see `workflow-runs.md`
- marks failed imports failed and does not retry automatically

For preprocessing, BIOMERO.importer runs external containers through Podman-in-Podman. That requires the privilege model documented in `permissions-and-deployment.md`.

## Logs

Importer logs:

```text
logs/biomero-importer/app.logs
logs/biomero-importer/cli.<UUID>*.errs
```

Analyzer result logs:

```text
/data/<group>/.analyzed/<workflow-uuid>/<timestamp>/omero-<job_id>.log
```

Useful log commands:

```bash
tail -f logs/biomero-importer/app.logs
sudo docker compose logs --tail=200 biomero-importer biomeroworker
```

## Retry Failed Import Order

A failed order can be retried by setting it back to pending in the BIOMERO DB. Confirm schema/stage names in the running DB first.

Example from docs:

```sql
UPDATE imports
SET stage = 'Import Pending'
WHERE uuid = '00000000-0000-0000-0000-000000000000';
```

## Troubleshooting Patterns

Results end up on OMERO server storage:

- `IMPORTER_ENABLED=true` is missing on `biomeroworker`
- `biomero-importer` Python library is missing in worker venv

Upload order created but never completes:

- importer container is stopped
- worker/importer/web point at different `INGEST_TRACKING_DB_URL`
- importer logs show OMERO CLI or permission failures

Files not found:

- `/data` mount mismatch between worker, importer, and server
- `biomero-config.json` maps group to a non-existent path

PermissionError writing `.analyzed`:

- worker UID cannot write the group base path
- first run for a group cannot create `/data/<group>`

Import polling timeout:

- default timeout is one hour
- large datasets or slow import settings may need tuning

## Test Assets

Repo test images:

```text
biomero-importer/tests/Barbie1.tif
biomero-importer/tests/Barbie2.tif
biomero-importer/tests/Barbie3.tif
```

Common in-container paths:

```text
/auto-importer/tests/Barbie1.tif
/auto-importer/tests/Barbie2.tif
/auto-importer/tests/Barbie3.tif
```

## Importer Version Comes From the Submodule

The importer image builds from the `biomero-importer/` git submodule, not from
`BIOMERO_IMPORTER_VERSION`. That pin only controls what the worker and web
images install from pip. The two can disagree silently:

```text
.env.shared:  BIOMERO_IMPORTER_VERSION=1.4.2   <- worker and web, via pip
submodule:    v1.3.0                           <- the importer image
```

`make doctor` reports both the submodule tag and the version inside the built
image. Check it after any version bump.

To move the importer:

```bash
cd biomero-importer && git fetch --tags && git checkout v<version>
cd .. && make rebuild:biomero-importer
make doctor
```

Moving the submodule is not enough on its own. The image keeps whatever source
it was last built from until it is rebuilt, so `doctor` can report a correct
submodule and a stale image at the same time.

A fresh clone has an empty `biomero-importer/` and the build fails outright.
Run `make init` first.
