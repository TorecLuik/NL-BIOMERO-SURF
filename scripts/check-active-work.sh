#!/usr/bin/env bash
# Read-only active-work check. --require-idle gates deployments.
set -uo pipefail
cd "$(dirname "$0")/.."
require_idle=0
[[ "${1:-}" == --require-idle ]] && require_idle=1
problem=0
compose() { sudo -n docker compose "$@"; }
query() { compose exec -T database-biomero psql -U biomero -d biomero -Atc "$1" 2>/dev/null; }

tasks="$(query "SELECT count(*) FROM biomero_task_execution WHERE end_time IS NULL" )"
# Detached launcher tasks are durable control records, not executing work.
# Exempt one only when the source workflow is terminal; leave history intact.
# libpq enforces read-only connections, including tracker setup/table checks.
terminal_launchers=0
if [[ "$tasks" =~ ^[0-9]+$ ]] && (( tasks > 0 )); then
  if counts="$(compose exec -T -e 'PGOPTIONS=-c default_transaction_read_only=on' biomeroworker /opt/omero/server/venv3/bin/python - <<'PYTHON'
from sqlalchemy import text
from biomero import SlurmClient
from biomero.database import EngineManager, TaskExecution
from biomero.eventsourcing import is_launcher_task

with SlurmClient.from_config(init_slurm=False, config_only=False) as client:
    session = EngineManager.get_session()
    assert session.execute(text("SHOW transaction_read_only")).scalar() == "on"
    rows = session.query(TaskExecution).filter_by(end_time=None).all()
    terminal_launchers = 0
    for row in rows:
        task = client.workflowTracker.repository.get(row.task_id)
        if is_launcher_task(task):
            workflow = client.workflowTracker.repository.get(task.workflow_id)
            if workflow.finished:
                terminal_launchers += 1
    print(f"ACTIVE_WORK_COUNTS={len(rows) - terminal_launchers},{terminal_launchers}")
PYTHON
  )"; then
    counts="$(printf '%s\n' "$counts" | sed -n 's/^ACTIVE_WORK_COUNTS=//p')"
    if [[ "$counts" =~ ^[0-9]+,[0-9]+$ ]]; then
      tasks="${counts%,*}"
      terminal_launchers="${counts#*,}"
    else
      printf 'NOT TESTED: detached task classification unavailable; retaining raw unfinished count\n'
    fi
  else
    printf 'NOT TESTED: detached task classification failed; retaining raw unfinished count\n'
  fi
fi
imports="$(query "SELECT count(*) FROM (SELECT DISTINCT ON (uuid) uuid,stage,timestamp FROM imports ORDER BY uuid,timestamp DESC) q WHERE stage NOT IN ('Import Completed','Import Failed')" )"
if [[ "$tasks" =~ ^[0-9]+$ && "$imports" =~ ^[0-9]+$ ]]; then
  printf 'PASS: active-work tracking readable; unfinished tasks=%s, open imports=%s, terminal detached launchers=%s\n' "$tasks" "$imports" "$terminal_launchers"
  if (( tasks > 0 || imports > 0 )); then
    printf 'WARN: production work is active; coordinate with the operator before disruption\n'
    problem=1
  fi
elif ! sudo -n test -s /data/surf-biomero-storage/database-biomero/PG_VERSION; then
  printf 'N/A: BIOMERO database has not been initialized on this mounted volume\n'
else
  printf 'NOT TESTED: BIOMERO task/import tracking unavailable\n'
  problem=1
fi
if queue="$(compose exec -T biomeroworker ssh -o BatchMode=yes -o ConnectTimeout=10 spider 'squeue -u $USER -h' 2>/dev/null)"; then
  jobs="$(printf '%s\n' "$queue" | sed '/^$/d' | wc -l)"
  printf 'PASS: Spider queue queried; jobs=%s\n' "$jobs"
  if (( jobs > 0 )); then printf 'WARN: Spider jobs are queued or running\n'; problem=1; fi
elif ! sudo -n test -s /data/surf-biomero-storage/database-biomero/PG_VERSION; then
  printf 'N/A: Spider worker is not yet deployed on this fresh volume\n'
else
  printf 'NOT TESTED: Spider queue unavailable\n'
  problem=1
fi
if (( require_idle && problem )); then
  printf 'FAIL: deployment gate cannot confirm idle production work\n' >&2
  exit 1
fi
