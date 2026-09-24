#!/usr/bin/env bash
# Evidence inventory; every operation is read-only.
set -uo pipefail
cd "$(dirname "$0")/.."
failures=0
pass() { printf 'PASS: %s\n' "$1"; }
warn() { printf 'WARN: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; failures=$((failures+1)); }
not_tested() { printf 'NOT TESTED: %s\n' "$1"; }
compose() { sudo -n docker compose "$@"; }

printf 'Changes performed: None — read-only audit\n'
if python3 scripts/check-storage-mount.py; then :; else failures=$((failures+1)); fi
for file in docker-compose.yml opensearch-compose.yml; do
  if sudo -n docker compose -f "$file" config --quiet >/dev/null 2>&1; then pass "$file resolves"; else fail "$file does not resolve"; fi
done
branch="$(git -c safe.directory="$PWD" branch --show-current 2>/dev/null)"
commit="$(git -c safe.directory="$PWD" rev-parse --short HEAD 2>/dev/null)"
upstream="$(git -c safe.directory="$PWD" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)"
printf 'Git: branch=%s commit=%s upstream=%s\n' "${branch:-unknown}" "${commit:-unknown}" "${upstream:-none}"
if [[ -z "$(git -c safe.directory="$PWD" status --porcelain 2>/dev/null)" ]]; then pass 'working tree clean'; else warn 'working tree has local changes (inspect before editing or staging)'; fi
expected=(database database-biomero omeroserver omeroworker-1 biomeroworker omeroweb biomero-importer metabase opensearch opensearch-dashboards fluent-bit)
running="$(compose ps --status running --format '{{.Service}}' 2>/dev/null)"
for service in "${expected[@]}"; do
  if grep -qx "$service" <<<"$running"; then pass "container running: $service"; else fail "container unavailable: $service"; fi
done
for service in database database-biomero; do
  if compose exec -T "$service" pg_isready -q >/dev/null 2>&1; then pass "database ready: $service"; else fail "database not ready: $service"; fi
done
if curl -fsS -o /dev/null --max-time 15 http://127.0.0.1:4080/webclient/login/; then pass 'OMERO.web internal login page'; else fail 'OMERO.web internal login page'; fi
host="$(hostname -f 2>/dev/null)"
if [[ -n "$host" ]] && curl -fsS -o /dev/null --max-time 15 "https://$host/webclient/login/"; then pass 'OMERO.web external HTTPS'; else warn 'OMERO.web external HTTPS unavailable or TLS invalid'; fi
for port in 4063 4064; do
  if timeout 3 bash -c "</dev/tcp/127.0.0.1/$port" 2>/dev/null; then pass "OMERO port $port listening locally"; else fail "OMERO port $port unavailable locally"; fi
done
if compose exec -T omeroserver sh -c 'test -d /data && test -d /OMERO'; then pass 'OMERO sees /data and /OMERO'; else fail 'OMERO storage visibility'; fi
for service in biomeroworker omeroweb biomero-importer; do
  if compose exec -T "$service" test -d /data >/dev/null 2>&1; then pass "$service sees /data"; else fail "$service cannot see /data"; fi
done
broken="$(compose exec -T omeroserver sh -c 'find /OMERO/ManagedRepository -type l ! -exec test -e {} \; -print' 2>/dev/null | wc -l)"
if [[ "$broken" == 0 ]]; then pass 'ManagedRepository links resolve'; else warn "$broken broken ManagedRepository links (no cleanup performed)"; fi
for item in database database-biomero omero; do
  owner="$(sudo -n stat -c '%u:%g' "/data/surf-biomero-storage/$item" 2>/dev/null)"
  case "$item:$owner" in database:999:999|database-biomero:999:999|omero:1000:0) pass "storage owner $item=$owner" ;; *) warn "storage owner $item=$owner (inspect before changing)" ;; esac
done
for path in / "$(sudo -n docker info --format '{{.DockerRootDir}}' 2>/dev/null)" /data/surf-biomero-storage; do
  if [[ -n "$path" ]]; then df -hP "$path" | tail -1; df -iP "$path" | tail -1; fi
done
sudo -n docker system df 2>/dev/null || not_tested 'Docker image and cache usage'
if systemctl is-enabled --quiet nl-biomero.service && systemctl is-active --quiet nl-biomero.service; then pass 'boot service enabled and active'; else warn 'boot service not both enabled and active'; fi
if systemctl is-enabled --quiet nl-biomero-backup.timer && systemctl is-active --quiet nl-biomero-backup.timer; then pass 'backup timer enabled and active'; else warn 'backup timer not both enabled and active'; fi
if curl -fsS -o /dev/null --max-time 10 http://127.0.0.1:9200/_cluster/health; then pass 'OpenSearch API answers'; else warn 'OpenSearch API unavailable'; fi
if curl -fsS -o /dev/null --max-time 10 http://127.0.0.1:5601/logs/api/status; then pass 'OpenSearch Dashboards API answers'; else warn 'OpenSearch Dashboards API unavailable'; fi
if curl -fsS -o /dev/null --max-time 10 http://127.0.0.1:3000/api/health; then pass 'Metabase API answers'; else warn 'Metabase API unavailable'; fi
active="$(compose exec -T database-biomero psql -U biomero -d biomero -Atc "SELECT count(*) FROM biomero_task_execution WHERE end_time IS NULL AND start_time > now()-interval '6 hours'" 2>/dev/null)"
if [[ "$active" =~ ^[0-9]+$ ]]; then printf 'PASS: workflow tracking queried; %s unfinished tasks in last 6h\n' "$active"; else not_tested 'active workflow tracking query'; fi
imports="$(compose exec -T database-biomero psql -U biomero -d biomero -Atc "SELECT COALESCE(string_agg(stage||':'||n,', '),'none') FROM (SELECT stage,count(*) n FROM (SELECT DISTINCT ON (uuid) uuid,stage,timestamp FROM imports WHERE timestamp > now()-interval '6 hours' ORDER BY uuid,timestamp DESC) q GROUP BY stage ORDER BY stage) counts" 2>/dev/null)"
if [[ -n "$imports" ]]; then printf 'PASS: recent import states (latest per UUID): %s\n' "$imports"; else not_tested 'recent import tracking query'; fi
if compose exec -T biomeroworker ssh -o BatchMode=yes -o ConnectTimeout=10 spider 'squeue -u $USER -h' >/dev/null 2>&1; then pass 'Spider Slurm queue reachable'; else warn 'Spider Slurm queue unreachable'; fi
if curl -fsS --max-time 10 http://127.0.0.1:9200/_plugins/_ism/policies/biomero-logs-retention >/dev/null 2>&1; then pass 'OpenSearch retention policy present'; else warn 'OpenSearch retention policy unavailable'; fi
if curl -fsS --max-time 10 'http://127.0.0.1:9200/biomero-logs/_count' 2>/dev/null | grep -q '"count"'; then pass 'biomero-logs index readable'; else warn 'biomero-logs index unavailable'; fi
if curl -fsS --max-time 10 'http://127.0.0.1:9200/_plugins/_ism/explain/biomero-logs*' 2>/dev/null | jq -e 'to_entries | any(.[]; .value.policy_id == "biomero-logs-retention")' >/dev/null; then pass 'biomero-logs concrete index is retention-managed'; else warn 'biomero-logs index retention not verified'; fi
./scripts/check-active-work.sh || not_tested 'active-work probe'
./scripts/verify-backup-readonly.sh || { warn 'latest backup verification incomplete'; failures=$((failures+1)); }
printf 'NOT TESTED: authenticated browser flows, image rendering, mutating imports and workflows\n'
if (( failures )); then exit 1; fi
