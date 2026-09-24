---
name: omero-biomero-expert
description: Operate and diagnose the NL-BIOMERO production Docker Compose stack, its attached storage, Spider workflows, imports, logging, and backups.
---

# OMERO/BIOMERO expert

This is a public-facing production service. Work from `/opt/omero/NL-BIOMERO`. Read [SETUP.md](../../../SETUP.md), [deployment_docs/deployment.md](../../../deployment_docs/deployment.md), and [deployment_docs/runbook.md](../../../deployment_docs/runbook.md) before operational work. Follow this server's live state when generic examples differ. Never print secrets, `.env`, container environments, credentials, dumps, private configuration, or connection strings.

## Choose the lifecycle explicitly

| Intent | Entry point | Effects |
| --- | --- | --- |
| Configuration drift | `make doctor` | Read-only |
| Prerequisites | `make check` | Read-only preflight |
| Current state | `make audit` | Read-only audit |
| Running application | `make smoke` | Read-only smoke; no import or workflow |
| Latest backup | `make backup-verify` | Read-only checksum and archive checks |
| Spider access | `make spider` | Interactive SSH from inside `biomeroworker` |
| Deployment | `make deploy` | Builds, writes config, starts both Compose stacks |
| Backup | `make backup` | Captures a new backup set; requires separate authorization |
| Restore | Runbook procedure | Destructive; separate outage plan |

Start with `make` to list the current targets and use the Makefile wrapper for routine operations. Use `make ps` for container state; `make doctor`, `make check`, `make audit`, `make smoke`, `make active-work`, and `make backup-verify` for read-only checks; and `make config` or `make gpu` to inspect effective BIOMERO and Slurm settings. Use `make logs:SVC` for one Compose service. These targets are the supported entry points on this server; inspect their definitions before assuming a target is read-only or invoking it in automation.

Use `make spider` for interactive SSH to Spider **from inside `biomeroworker`**, the same connection path BIOMERO uses. Use `make smoke` for a read-only worker-to-Spider Slurm reachability check and `make active-work` for the queue and active-task check. A host account's inability to traverse the checkout's `.ssh/` does not prove the worker cannot reach Spider; report the host-side check separately. Do not run interactive `make spider` as a status or audit probe.

`docker-compose.yml` holds the core services; `opensearch-compose.yml` holds logging. `make up` starts both. Use Compose **service names**, never derived container names. The Makefile invokes `sudo docker compose`; for direct commands use `sudo -n docker compose`. No ACC paths, rootless host Podman, or ACC systemd environment apply here. Podman exists only inside `biomero-importer` for conversion.

Read [references/operations.md](references/operations.md) for deployment gates, active work, audits, backup truthfulness, and test isolation. **For every deployment-status, smoke-audit, post-deployment, and post-integration-test report, read and follow [references/status-report.md](references/status-report.md).** A running container is evidence only that a process is running; verify application readiness separately.

## Production Git delivery

For every production update to tracked code, configuration, documentation, or this skill, commit the intended changes and push them to the configured remote production branch. Verify the remote branch contains the commit and record its full commit ID. A production deployment must be based on that pushed commit; do not call local-only changes delivered or deploy them as the planned update. Review the exact diff and staged files first. Never stage secrets, private configuration, logs, database files, backups, or storage content. Follow [references/operations.md](references/operations.md) for the Git-delivery checks. Pushing a commit does not authorize a restart or deployment.

## Storage is production data

The attached XFS volume must be mounted at `/data/surf-biomero-storage`, and Compose must resolve database, OMERO, and L-Drive binds there before **any** start, restart, rebuild, or redeploy. `python3 scripts/check-storage-mount.py` checks this without writing. An existing directory at the mount path proves nothing. Never initialize PostgreSQL, OMERO, or L-Drive on the VM root filesystem.

`/data/surf-biomero-storage/L-Drive` appears as `/data` in containers. In-place imports and workflow results may depend on links to `.analyzed`, `.processed`, `uploads`, `tus_destination`, source and converted data, and group folders. Treat all as persistent. Never clean them by prefix, wildcard, or folder name. On disk pressure, identify the affected filesystem and safe candidates; do not delete images, volumes, cache, logs, backups, repository files, or L-Drive contents without explicit authorization.

Before a disruptive operation, check recent unfinished BIOMERO tasks, active imports, and Spider queue jobs, then obtain operator approval. Read-only inspection requires no approval. Do not run a mutating importer or analyzer test without explicit test selection. Copy minimum fixtures to a unique isolated location first, record exact paths and IDs, and clean only recorded artifacts after verifying results. Preserve failed-run evidence and original fixtures.

## Route diagnosis to focused references

- [operations.md](references/operations.md): lifecycle, safety gates, tests, and backups.
- [status-report.md](references/status-report.md): required structure, classification, and evidence for operational reports.
- [verification-pitfalls.md](references/verification-pitfalls.md): probes that falsely pass, especially password tests and cached OMERO sessions.
- [permissions-and-deployment.md](references/permissions-and-deployment.md): permissions, boot, ports, nginx, logs and recovery.
- [importer-analyzer-storage.md](references/importer-analyzer-storage.md): importer, analyzer, storage and tracking.
- [workflow-runs.md](references/workflow-runs.md): trace a workflow UUID and output failures.
- [slurm-and-gpu.md](references/slurm-and-gpu.md): Spider, Slurm, GPUs and image pulls.
- [metabase-dashboards.md](references/metabase-dashboards.md): dashboard diagnosis and repair.
- [fresh-vm.md](references/fresh-vm.md): empty-volume setup.

Repair commands such as `make metabase-dashboards`, `make logs-retention`, password rotation, and service restarts are mutating operations. Keep them out of status and smoke checks. See [deployment_docs/pipeline-tests.md](../../../deployment_docs/pipeline-tests.md) for browser integration tests; those require a separate explicit selection and isolated fixtures.
