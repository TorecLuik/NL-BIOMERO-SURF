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
imports="$(query "SELECT count(*) FROM (SELECT DISTINCT ON (uuid) uuid,stage,timestamp FROM imports ORDER BY uuid,timestamp DESC) q WHERE stage NOT IN ('Import Completed','Import Failed')" )"
if [[ "$tasks" =~ ^[0-9]+$ && "$imports" =~ ^[0-9]+$ ]]; then
  printf 'PASS: active-work tracking readable; unfinished tasks=%s, open imports=%s\n' "$tasks" "$imports"
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
