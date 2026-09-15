#!/usr/bin/env bash
# Bring a bare VM to a running, checked NL-BIOMERO stack in one command.
#
# This wraps scripts/deploy-local-stack.sh with the checks that are easy to
# forget when rebuilding production from scratch: prerequisites, required
# secrets, Spider reachability, and post-deployment smoke tests.
#
# Usage:
#   scripts/bootstrap-prod.sh              # preflight, deploy, smoke test
#   scripts/bootstrap-prod.sh --check-only # preflight only, change nothing
#   scripts/bootstrap-prod.sh --skip-smoke # deploy without smoke tests
#
# Prerequisites that must exist before running, because they cannot be
# regenerated from the repository:
#   .env.keys    dotenvx private keys, needed to decrypt .env.secrets
#   .ssh/id_rsa  Spider SSH key registered with the SPIDER_USER account
set -euo pipefail

PROJECT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT_DIR}"

CHECK_ONLY=0
SKIP_SMOKE=0
for arg in "$@"; do
  case "${arg}" in
    --check-only) CHECK_ONLY=1 ;;
    --skip-smoke) SKIP_SMOKE=1 ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

FAILURES=0
ok()   { printf '  [ ok ] %s\n' "$1"; }
warn() { printf '  [warn] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------- preflight --
echo "== Preflight =="

if command -v docker >/dev/null 2>&1; then
  ok "docker present: $(docker --version | cut -d, -f1)"
else
  fail "docker is not installed"
fi

if docker compose version >/dev/null 2>&1 || sudo docker compose version >/dev/null 2>&1; then
  ok "docker compose plugin present"
else
  fail "docker compose plugin is missing"
fi

# Building the worker and web images needs room for large intermediate layers.
AVAIL_GB="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
if [[ "${AVAIL_GB}" -ge 40 ]]; then
  ok "disk space on /: ${AVAIL_GB}G available"
elif [[ "${AVAIL_GB}" -ge 25 ]]; then
  warn "disk space on /: ${AVAIL_GB}G available; builds may be tight, 40G is comfortable"
else
  fail "disk space on /: ${AVAIL_GB}G available; need at least 25G to build the images"
fi

# Secrets that cannot be reconstructed from the repository.
if [[ -f .env.keys ]]; then
  ok ".env.keys present (dotenvx private keys)"
elif [[ -f .env ]]; then
  warn ".env.keys missing, but .env exists; encrypted secrets cannot be re-rendered"
else
  fail ".env.keys and .env are both missing; restore them from the backup first"
fi

if [[ -f .ssh/id_rsa ]]; then
  ok "project SSH key present"
else
  fail ".ssh/id_rsa missing; restore the Spider key from the backup first"
fi

# Version pins the build depends on.
if [[ -f .env.shared ]]; then
  ok "pins: $(grep -E '^(BIOMERO_VERSION|OMERO_BIOMERO_VERSION|BIOMERO_IMPORTER_VERSION)=' .env.shared | tr '\n' ' ')"
else
  fail ".env.shared is missing"
fi

# Spider identity and reachability. Non-fatal: the stack still starts without
# Slurm, it just cannot run workflows.
SPIDER_USER_VAL="$(grep -hE '^SPIDER_USER=' .env .env.shared 2>/dev/null | tail -1 | cut -d= -f2- || true)"
if [[ -n "${SPIDER_USER_VAL}" ]]; then
  ok "SPIDER_USER is set"
  if timeout 25 ssh -F .ssh/config -o BatchMode=yes -o ConnectTimeout=15 spider 'true' 2>/dev/null; then
    ok "Spider SSH reachable"
    if timeout 25 ssh -F .ssh/config -o BatchMode=yes spider 'sinfo -h -o "%P"' 2>/dev/null | grep -q .; then
      ok "Spider Slurm responding to sinfo"
    else
      warn "Spider reachable but sinfo returned nothing"
    fi
  else
    warn "Spider SSH not reachable; stack will start but workflows cannot run"
  fi
else
  warn "SPIDER_USER is not set; set it before running workflows"
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  echo
  echo "Preflight failed with ${FAILURES} blocking problem(s); not deploying." >&2
  exit 1
fi
echo "Preflight passed."

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
  echo "--check-only given; stopping before deployment."
  exit 0
fi

# --------------------------------------------------------------- deployment --
echo
echo "== Deploying stack =="
"${PROJECT_ROOT_DIR}/scripts/deploy-local-stack.sh"

if [[ "${SKIP_SMOKE}" -eq 1 ]]; then
  echo "--skip-smoke given; deployment finished without smoke tests."
  exit 0
fi

# ------------------------------------------------------------- smoke tests --
echo
echo "== Smoke tests =="

compose() { sudo docker compose "$@"; }

# Services need a moment to come up before any check is meaningful.
echo "  waiting up to 180s for services to settle..."
for _ in $(seq 1 36); do
  if compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -q omeroserver; then
    break
  fi
  sleep 5
done

SMOKE_FAILURES=0
smoke_ok()   { printf '  [ ok ] %s\n' "$1"; }
smoke_fail() { printf '  [FAIL] %s\n' "$1"; SMOKE_FAILURES=$((SMOKE_FAILURES + 1)); }

# 1. Every expected service is running.
EXPECTED_SERVICES=(database database-biomero omeroserver omeroweb biomeroworker)
RUNNING="$(compose ps --status running --format '{{.Service}}' 2>/dev/null || true)"
for svc in "${EXPECTED_SERVICES[@]}"; do
  if grep -qx "${svc}" <<<"${RUNNING}"; then
    smoke_ok "service running: ${svc}"
  else
    smoke_fail "service not running: ${svc}"
  fi
done

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

# 3. The web front end responds.
if curl -fsS -o /dev/null --max-time 30 http://localhost:4080/webclient/login/; then
  smoke_ok "OMERO.web login page responds"
else
  smoke_fail "OMERO.web login page did not respond on :4080"
fi

# 4. Installed versions match the pins, so a stale image is caught here rather
#    than during a workflow run.
WORKER_VERSIONS="$(compose exec -T biomeroworker /opt/omero/server/venv3/bin/pip list 2>/dev/null \
  | grep -iE '^(biomero|biomero-importer|ezomero|zarr) ' || true)"
if [[ -n "${WORKER_VERSIONS}" ]]; then
  smoke_ok "worker packages: $(tr -s ' ' <<<"${WORKER_VERSIONS}" | tr '\n' ';')"
  EXPECTED_BIOMERO="$(grep -E '^BIOMERO_VERSION=' .env.shared | cut -d= -f2)"
  ACTUAL_BIOMERO="$(awk '/^biomero /{print $2}' <<<"${WORKER_VERSIONS}")"
  if [[ "${ACTUAL_BIOMERO}" == "${EXPECTED_BIOMERO}" ]]; then
    smoke_ok "worker BIOMERO version matches pin (${EXPECTED_BIOMERO})"
  else
    smoke_fail "worker BIOMERO is ${ACTUAL_BIOMERO}, expected ${EXPECTED_BIOMERO}"
  fi
else
  smoke_fail "could not read worker package versions"
fi

# 5. The runtime patch is present in the installed BIOMERO.
if compose exec -T biomeroworker grep -q '_nl_biomero_verify_outputs' \
     /opt/omero/server/venv3/lib/python3.11/site-packages/biomero/slurm_client.py 2>/dev/null; then
  smoke_ok "BIOMERO output-verification patch applied in worker"
else
  smoke_fail "BIOMERO output-verification patch missing in worker"
fi

# 6. The worker can reach Spider, which is what actually runs workflows.
if compose exec -T biomeroworker ssh -o BatchMode=yes -o ConnectTimeout=15 spider 'sinfo -h -o "%P"' >/dev/null 2>&1; then
  smoke_ok "worker can reach Spider Slurm"
else
  smoke_fail "worker cannot reach Spider Slurm (check .ssh mount and known_hosts)"
fi

echo
if [[ "${SMOKE_FAILURES}" -gt 0 ]]; then
  echo "Smoke tests finished with ${SMOKE_FAILURES} failure(s)." >&2
  echo "Inspect with: sudo docker compose ps && sudo docker compose logs --tail=120" >&2
  exit 1
fi

echo "All smoke tests passed."
echo
echo "Still to verify by hand, because they need real data or a browser:"
echo "  - run a CPU workflow, a MIG GPU workflow, and deconvolve_plate on full A100"
echo "  - confirm workflow results import back into OMERO"
echo "  - confirm the BIOMERO importer picks up files under /data"
echo "  - open OMERO.web and check the Metabase dashboards embed"
