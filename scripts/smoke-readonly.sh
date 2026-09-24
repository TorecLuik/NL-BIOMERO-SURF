#!/usr/bin/env bash
# Read-only checks of the running stack. No deployment, import or workflow submission.
set -euo pipefail
PROJECT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT_DIR}"
env_value() { grep -hE "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true; }
POSTGRES_USER="$(env_value POSTGRES_USER)"
POSTGRES_DB="$(env_value POSTGRES_DB)"
BIOMERO_POSTGRES_USER="$(env_value BIOMERO_POSTGRES_USER)"
BIOMERO_POSTGRES_DB="$(env_value BIOMERO_POSTGRES_DB)"
MB_DB_NAME="$(env_value MB_DB_NAME)"
PUBLIC_HOST="$(hostname -f 2>/dev/null || true)"
START_LOG_STACK="${START_LOG_STACK:-1}"
python3 scripts/check-storage-mount.py || exit 1


echo
echo "== Smoke tests =="

compose() { sudo -n docker compose "$@"; }

# Services need a moment to come up before any check is meaningful.
echo "  waiting up to 180s for services to settle..."
for _ in $(seq 1 36); do
  if compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -q omeroserver; then
    break
  fi
  sleep 5
done

SMOKE_FAILURES=0
SMOKE_SKIPPED=0
SMOKE_WARNINGS=0
smoke_ok()   { printf 'PASS: %s\n' "$1"; }
warn() { printf 'WARN: %s\n' "$1"; SMOKE_WARNINGS=$((SMOKE_WARNINGS + 1)); }
smoke_fail() { printf 'FAIL: %s\n' "$1"; SMOKE_FAILURES=$((SMOKE_FAILURES + 1)); }
# A check that cannot run because something it depends on is already broken.
# Reporting these as failures turns one dead service into a screenful of red
# and buries the cause among its consequences.
smoke_skip() { printf 'NOT TESTED: %s\n' "$1"; SMOKE_SKIPPED=$((SMOKE_SKIPPED + 1)); }

# 1. Every expected service is running.
EXPECTED_SERVICES=(database database-biomero omeroserver omeroworker-1 omeroweb biomeroworker biomero-importer metabase)
if [[ "${START_LOG_STACK}" != 0 ]]; then EXPECTED_SERVICES+=(opensearch opensearch-dashboards fluent-bit); fi
RUNNING="$(compose ps --status running --format '{{.Service}}' 2>/dev/null || true)"
for svc in "${EXPECTED_SERVICES[@]}"; do
  if grep -qx "${svc}" <<<"${RUNNING}"; then
    smoke_ok "service running: ${svc}"
  else
    smoke_fail "service not running: ${svc}"
  fi
done

# Checks 4 to 6 all exec into biomeroworker, so without it they report the same
# outage three more times. Decide once whether they can run at all.
if grep -qx biomeroworker <<<"${RUNNING}"; then
  WORKER_UP=1
else
  WORKER_UP=0
fi

# 2. Both databases accept queries.
if compose exec -T database psql -U "${POSTGRES_USER:-omero}" -d "${POSTGRES_DB:-omero}" -c 'SELECT 1' >/dev/null 2>&1; then
  smoke_ok "OMERO database accepts queries"
else
  smoke_fail "OMERO database did not accept a query"
fi

if compose exec -T database-biomero psql -U "${BIOMERO_POSTGRES_USER:-biomero}" -d "${BIOMERO_POSTGRES_DB:-biomero}" -c 'SELECT 1' >/dev/null 2>&1; then
  smoke_ok "BIOMERO database accepts queries"
else
  smoke_fail "BIOMERO database did not accept a query"
fi

# Metabase keeps its application database here too, and it is created by
# deploy-local-stack.sh rather than by Postgres itself.
if compose exec -T database-biomero psql -U "${BIOMERO_POSTGRES_USER:-biomero}" -d "${MB_DB_NAME:-metabase}" -c 'SELECT 1' >/dev/null 2>&1; then
  smoke_ok "Metabase application database accepts queries"
else
  smoke_fail "Metabase application database did not accept a query"
fi

# 3. The web front end responds.
if curl -fsS -o /dev/null --max-time 30 http://localhost:4080/webclient/login/; then
  smoke_ok "OMERO.web login page responds"
else
  smoke_fail "OMERO.web login page did not respond on :4080"
fi

# 4. Installed versions match the pins, so a stale image is caught here rather
#    than during a workflow run.
if [[ "${WORKER_UP}" -eq 0 ]]; then
  smoke_skip "worker package versions (biomeroworker is not running)"
else
WORKER_VERSIONS="$(compose exec -T biomeroworker /opt/omero/server/venv3/bin/pip list 2>/dev/null \
  | grep -iE '^(biomero|biomero-importer|ezomero|zarr) ' || true)"
if [[ -n "${WORKER_VERSIONS}" ]]; then
  smoke_ok "worker packages: $(tr -s ' ' <<<"${WORKER_VERSIONS}" | tr '\n' ';')"
  EXPECTED_BIOMERO="$(grep -E '^BIOMERO_VERSION=' .env | cut -d= -f2)"
  ACTUAL_BIOMERO="$(awk '/^biomero /{print $2}' <<<"${WORKER_VERSIONS}")"
  if [[ "${ACTUAL_BIOMERO}" == "${EXPECTED_BIOMERO}" ]]; then
    smoke_ok "worker BIOMERO version matches pin (${EXPECTED_BIOMERO})"
  else
    smoke_fail "worker BIOMERO is ${ACTUAL_BIOMERO}, expected ${EXPECTED_BIOMERO}"
  fi
else
  smoke_fail "could not read worker package versions"
fi
fi

# 5. The runtime patches are present. Both fail the same way if they silently
#    stop applying: a workflow that runs correctly still fails at 90%.
if [[ "${WORKER_UP}" -eq 0 ]]; then
  smoke_skip "BIOMERO output-verification patch (biomeroworker is not running)"
elif compose exec -T biomeroworker grep -q '_nl_biomero_verify_outputs' \
     /opt/omero/server/venv3/lib/python3.11/site-packages/biomero/slurm_client.py 2>/dev/null; then
  smoke_ok "BIOMERO output-verification patch applied in worker"
else
  smoke_fail "BIOMERO output-verification patch missing in worker"
fi

if grep -qx omeroserver <<<"${RUNNING}"; then
  ROI_GUARD_MISSING=()
  for _script in SLURM_Import_Results.py SLURM_Get_Results.py; do
    if ! compose exec -T omeroserver grep -q '\[\] if not _roi_target_ids else \[' \
         "/opt/omero/server/OMERO.server/lib/scripts/biomero/_data/${_script}" 2>/dev/null; then
      ROI_GUARD_MISSING+=("${_script}")
    fi
  done
  if [[ "${#ROI_GUARD_MISSING[@]}" -eq 0 ]]; then
    smoke_ok "empty ROI_Target_Image_IDs guard applied in server scripts"
  else
    smoke_fail "ROI_Target_Image_IDs guard missing in ${ROI_GUARD_MISSING[*]}; imports will fail at 90%"
  fi
else
  smoke_skip "ROI_Target_Image_IDs guard (omeroserver is not running)"
fi

# 6. The worker can reach Spider, which is what actually runs workflows.
if [[ "${WORKER_UP}" -eq 0 ]]; then
  smoke_skip "worker to Spider Slurm (biomeroworker is not running)"
elif compose exec -T biomeroworker ssh -o BatchMode=yes -o ConnectTimeout=15 spider 'sinfo -h -o "%P"' >/dev/null 2>&1; then
  smoke_ok "worker can reach Spider Slurm"
else
  smoke_fail "worker cannot reach Spider Slurm (check .ssh mount and known_hosts)"
fi

# 7. Observability, which deploy-local-stack.sh starts unless START_LOG_STACK=0.
# Warn rather than fail: the analysis stack works without it.
if [[ "${START_LOG_STACK:-1}" == "0" ]]; then
  printf 'N/A: log stack disabled by START_LOG_STACK=0\n'
else
  # OpenSearch reports green or yellow when usable; yellow is normal on a
  # single node, where replica shards stay unassigned.
  OS_HEALTH="$(curl -fsS --max-time 20 http://localhost:9200/_cluster/health 2>/dev/null \
    | sed -n 's/.*"status" *: *"\([a-z]*\)".*/\1/p' || true)"
  case "${OS_HEALTH}" in
    green|yellow) smoke_ok "OpenSearch cluster is ${OS_HEALTH}" ;;
    "")           warn "OpenSearch not responding on :9200; log viewer will be empty" ;;
    *)            warn "OpenSearch cluster is ${OS_HEALTH}" ;;
  esac

  if curl -fsS -o /dev/null --max-time 25 http://localhost:5601/logs/api/status 2>/dev/null; then
    smoke_ok "OpenSearch Dashboards responds under /logs"
    # Answering is not the same as being usable: without an index pattern,
    # /logs opens on a setup screen with every log indexed and none shown.
    if curl -fsS --max-time 25 -H 'osd-xsrf: true' \
         'http://localhost:5601/logs/api/saved_objects/_find?type=index-pattern&per_page=20' \
         2>/dev/null | grep -q 'biomero-logs'; then
      smoke_ok "/logs has the biomero-logs index pattern"
    else
      warn "no biomero-logs index pattern; /logs opens on its setup screen"
      warn "  dashboards-init creates it: docker logs dashboards-init"
    fi
  else
    warn "OpenSearch Dashboards not responding on :5601 (it can take a minute to start)"
  fi

  # Fluent Bit can run while failing to deliver, so check that documents are
  # actually arriving rather than trusting container state.
  if [[ -n "${OS_HEALTH}" ]]; then
    COUNT_1="$(curl -fsS --max-time 20 http://localhost:9200/biomero-logs/_count 2>/dev/null \
      | sed -n 's/.*"count" *: *\([0-9]*\).*/\1/p' || true)"
    if [[ -z "${COUNT_1}" ]]; then
      warn "biomero-logs index missing; check the opensearch-init container"
    else
      sleep 20
      COUNT_2="$(curl -fsS --max-time 20 http://localhost:9200/biomero-logs/_count 2>/dev/null \
        | sed -n 's/.*"count" *: *\([0-9]*\).*/\1/p' || true)"
      if [[ -n "${COUNT_2}" && "${COUNT_2}" -gt "${COUNT_1}" ]]; then
        smoke_ok "Fluent Bit is indexing into biomero-logs ($((COUNT_2 - COUNT_1)) new docs)"
      else
        warn "biomero-logs has ${COUNT_1} docs but is not growing; check: docker logs fluent-bit"
      fi
    fi
  fi
fi

# 8. The public URL, which is what users actually hit. Warn rather than fail:
# the stack is healthy even when host nginx is not configured yet.
if [[ -n "${PUBLIC_HOST}" ]]; then
  PUB_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    "https://${PUBLIC_HOST}/webclient/login/" 2>/dev/null || true)"
  case "${PUB_CODE}" in
    200|302) smoke_ok "public URL answers ${PUB_CODE}: https://${PUBLIC_HOST}/" ;;
    000|"")  warn "https://${PUBLIC_HOST}/ did not answer; check the nginx location block" ;;
    *)       warn "https://${PUBLIC_HOST}/webclient/login/ returned ${PUB_CODE}" ;;
  esac
fi

echo
if [[ "${SMOKE_FAILURES}" -gt 0 ]]; then
  if [[ "${SMOKE_SKIPPED}" -gt 0 ]]; then
    echo "Smoke tests finished with ${SMOKE_FAILURES} failure(s); ${SMOKE_SKIPPED} check(s) skipped because what they depend on is down." >&2
  else
    echo "Smoke tests finished with ${SMOKE_FAILURES} failure(s)." >&2
  fi
  echo "Inspect with: sudo docker compose ps && sudo docker compose logs --tail=120" >&2
  exit 1
fi

# Skipped checks never ran, so the suite cannot claim to have passed.
if [[ "${SMOKE_SKIPPED}" -gt 0 ]]; then
  echo "Smoke checks had ${SMOKE_SKIPPED} NOT TESTED item(s); validation coverage is incomplete." >&2
  exit 1
fi

if [[ "${SMOKE_WARNINGS}" -gt 0 ]]; then
  echo "Smoke checks completed with ${SMOKE_WARNINGS} warning(s)."
else
  echo "All smoke checks passed."
fi
echo
echo "Smoke checks do not exercise authenticated image use or a full workflow. The"
echo "end-to-end checks live in deployment_docs/pipeline-tests.md -- import,"
echo "segmentation, cell expansion and quantification, driven from the browser:"
echo "  make reference-data     fetch the public test images"
echo "                          then work through pipeline-tests.md"
echo
echo "Still needing something outside this VM:"
echo "  - OMERO.insight on 4063/4064, opened in the Research Cloud portal"
echo "  - a MIG GPU workflow and deconvolve_plate on full A100, which no"
echo "    reference image here exercises"
