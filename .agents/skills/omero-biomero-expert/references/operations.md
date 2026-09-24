# Production operations and reporting

## Before a deployment or restart

1. Record branch, commit, upstream, dirty files and submodule state. Preserve site-specific changes, especially `web/biomero-config.json`. Never stage private data.
2. Run `python3 scripts/check-storage-mount.py`. It requires the XFS mount at `/data/surf-biomero-storage` and checks resolved core Compose bind sources. Stop if it fails.
3. Run `sudo -n docker compose -f docker-compose.yml config --quiet` and the equivalent for `opensearch-compose.yml`; inspect service coverage and required configuration without printing secrets. Run `make doctor` and `make check`. **`volume-identity.sh check` writes `.env`**; `volume-identity.sh verify` compares without writing.
4. Run `make audit` and `make backup-verify`. Check root, Docker storage and attached-volume space and inodes. Inspect Docker image, cache and log usage without pruning anything. Check nginx/TLS, boot unit, Spider, both databases, storage owners, link integrity and backup age. Record checks that cannot run as NOT TESTED.
5. Run `make active-work` immediately before the operation. It checks all unfinished tasks, latest import stage per UUID, and Spider queue jobs; it blocks deployment if any are active or cannot be checked. For a focused recent task listing: `sudo -n docker compose exec -T database-biomero psql -U biomero -d biomero -Atc "SELECT task_name,start_time FROM biomero_task_execution WHERE end_time IS NULL AND start_time > now()-interval '6 hours'"`. Import tracking is in `imports`; inspect the latest stage per UUID, not historical stage counts. Spider: `sudo -n docker compose exec -T biomeroworker ssh spider 'squeue -u $USER -h'`. A query failure is NOT TESTED, not proof of an idle system. Obtain operator approval for the concrete deployment plan.
6. Run `make deploy`, then `make smoke`, `make audit` and `make backup-verify`. Give progress updates with elapsed times. Browser, importer and analyzer validation are separate and must be reported as NOT TESTED unless performed.

A `make deploy` result can pass while a feature is degraded. A running container alone is not application readiness. An outage, restore, credential rotation, nginx change, data cleanup or backup requiring quiescence needs its own authorization. Restore is destructive and requires an approved outage plan.

## Integration tests

Tiers: read-only smoke; isolated importer smoke; isolated analyzer smoke; extended importer formats; extended workflow chain; explicitly selected benchmark/full tests. Select mutating tiers explicitly; do not hide them inside `smoke`, `audit`, or `doctor`.

For each run, generate a unique ID and write a manifest outside production data containing exact test-created paths, OMERO object IDs, import UUIDs, workflow UUIDs, and Slurm job IDs. The fixtures under `/data/amsterdam_umc/` include `3dtiny.lif` and `cellssmall/experiment.db` with `images-0.db`; copy only required files into a uniquely named approved test directory under L-Drive. Keep the two `.db` files together. Never submit or rename the authoritative fixtures. Record timestamps for preparation, import, conversion, workflow, validation and cleanup. Verify the image previews or result pixels and metadata, not only `DONE`. Clean only manifest-listed artifacts, verify their removal, and retain failed-run evidence for diagnosis. No wildcard, prefix, or folder-name deletion.

## Backup evidence

`make backup-verify` reads the newest nightly set: marker, age, expected files, checksums, dump table of contents and tar readability. Older sets lack `COMPLETE`; report that as WARN. This is not a restore test. The nightly backup omits L-Drive, although imported images and results may point to the only pixels there. Backups under `/data/surf-biomero-storage` share the volume's failure domain. Do not claim off-host protection or an atomic database/filesystem recovery point without evidence of the actual transfer and consistency procedure. Do not run `make backup` merely to validate backup readiness: it writes a new set. Old-set deletion requires separate authorization.

## Reports

Follow [status-report.md](status-report.md) for every deployment-status, smoke-audit, post-deployment, and post-integration-test report. For an integration run, also include fixture identity, isolated test location, exact created IDs and paths, state transitions, final usability evidence, cleanup result, phase durations and total runtime.
