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
#   .env         deployment secrets; the only copy, so archive it somewhere safe
#   .ssh/slurm_access_key  cluster SSH key registered for the SPIDER_USER account
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

python3 scripts/check-storage-mount.py || exit 1

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
if [[ -f .env ]]; then
  ok ".env present (deployment secrets)"
else
  fail ".env is missing; restore it from your secrets archive before deploying"
fi

SLURM_KEY_NAME="$(grep -hE '^SLURM_ACCESS_KEY=' .env 2>/dev/null | tail -1 | cut -d= -f2-)"
SLURM_KEY_NAME="${SLURM_KEY_NAME:-slurm_access_key}"
if [[ ! -x .ssh ]]; then
  fail "cannot traverse .ssh with this account; host-side deployment access is unavailable"
elif [[ -f ".ssh/${SLURM_KEY_NAME}" ]]; then
  ok "cluster SSH key present (.ssh/${SLURM_KEY_NAME})"
else
  fail ".ssh/${SLURM_KEY_NAME} missing; check with the key owner"
fi

# Preflight resolves the key through $SLURM_ACCESS_KEY, so it passes happily on
# a deploy script that hardcodes some other name -- which is exactly how a
# renamed key once got past this point and aborted the deploy seconds later on
# "chmod: cannot access .ssh/id_rsa". Check the literal .ssh paths the deploy
# script will act on, not only the ones preflight knows how to build.
#
# Only the paths the deploy reads have to exist. It writes .ssh/config and
# .ssh/known_hosts itself, so requiring those up front blocked every fresh VM
# on a file that the next step was about to create. Derive the written ones
# from the script rather than listing them here, so a new one does not
# reintroduce the same false failure.
WRITTEN_SSH="$(grep -oE '(cat >|touch|ssh-keyscan[^>]*>>) *"\$\{SSH_DIR\}/[A-Za-z0-9._${}-]+' \
               scripts/deploy-local-stack.sh 2>/dev/null | sed 's#.*/##' | sort -u)"
STALE_SSH=()
while IFS= read -r name; do
  [[ -z "${name}" ]] && continue
  [[ "${name}" == "${SLURM_KEY_NAME}" || "${name}" == "${SLURM_KEY_NAME}.pub" ]] && continue
  grep -qxF "${name}" <<<"${WRITTEN_SSH}" && continue
  [[ -e ".ssh/${name}" ]] && continue
  STALE_SSH+=("${name}")
done < <(grep -oE '\$\{SSH_DIR\}/[A-Za-z0-9._-]+' scripts/deploy-local-stack.sh 2>/dev/null \
         | sed 's#.*/##' | sort -u)
if [[ ! -x .ssh ]]; then
  warn "deploy SSH path check NOT TESTED: .ssh is inaccessible to this account"
elif [[ "${#STALE_SSH[@]}" -gt 0 ]]; then
  fail "deploy script references .ssh files that do not exist: ${STALE_SSH[*]}"
  fail "  SLURM_ACCESS_KEY is ${SLURM_KEY_NAME}; the deploy would abort on the missing path"
else
  ok "deploy script's .ssh paths all resolve"
fi

# Public ingress. nginx is host-managed on SURF Research Cloud, so this only
# reports; it never edits host configuration.
NGINX_LOCATION=/etc/nginx/app-location-conf.d/omero-web.conf
if [[ -f "${NGINX_LOCATION}" ]]; then
  ok "nginx location block installed"
else
  warn "nginx location block not installed; the stack will run but stay unreachable from outside"
  warn "  sudo cp nginx/omero-web.conf ${NGINX_LOCATION} && sudo nginx -t && sudo systemctl reload nginx"
fi

# Per-VM hostname values. A wrong CSRF origin lets the stack start but blocks
# OMERO.web login, with an error that does not name the cause.
PUBLIC_HOST="$(hostname -f 2>/dev/null || true)"
ENV_FOR_HOST=.env
if [[ -n "${PUBLIC_HOST}" ]] \
   && grep -qE '^OMERO_CSRF_TRUSTED_ORIGINS=' "${ENV_FOR_HOST}" \
   && ! grep -E '^OMERO_CSRF_TRUSTED_ORIGINS=' "${ENV_FOR_HOST}" | grep -qF "${PUBLIC_HOST}"; then
  warn "OMERO_CSRF_TRUSTED_ORIGINS does not mention ${PUBLIC_HOST}; login will fail"
  warn "  make set-host HOST=${PUBLIC_HOST}"
else
  ok "hostname values match ${PUBLIC_HOST:-unknown}"
fi

# Credentials against the volume that holds the data. This runs before the
# completeness check below because it is what fills them in: on a reattached
# volume, the values the data fixes are left unset in .env and taken from the
# volume here. A .env that disagrees would otherwise fail only at
# authentication time, since Postgres and OMERO ignore them once initialised.
if ! "${PROJECT_ROOT_DIR}/scripts/volume-identity.sh" $([[ "${CHECK_ONLY}" -eq 1 ]] && echo verify || echo check); then
  fail "credentials do not match the storage volume"
fi

# Every key .env.example documents has to be present, non-empty, and actually
# filled in. Compose substitutes a missing value with the empty string, so
# without this a half-filled .env reaches the containers and fails there --
# Postgres initialising with a blank password rather than refusing to start.
if [[ -f .env.example && -f .env ]]; then
  MISSING_KEYS=()
  PLACEHOLDER_KEYS=()
  while IFS= read -r key; do
    if ! grep -qE "^${key}=" .env 2>/dev/null; then
      MISSING_KEYS+=("${key}")
      continue
    fi
    value="$(grep -hE "^${key}=" .env | tail -1 | cut -d= -f2-)"
    if [[ -z "${value}" ]]; then
      MISSING_KEYS+=("${key}")
    elif [[ "${value}" == *"CHANGE ME"* || "${value}" == *"CHANGE-ME"* ]]; then
      PLACEHOLDER_KEYS+=("${key}")
    fi
  done < <(grep -oE '^[A-Z_]+=' .env.example | tr -d '=' | sort -u)

  if [[ "${#MISSING_KEYS[@]}" -gt 0 ]]; then
    fail "missing or empty in .env: ${MISSING_KEYS[*]}"
  fi
  if [[ "${#PLACEHOLDER_KEYS[@]}" -gt 0 ]]; then
    fail "still a placeholder in .env: ${PLACEHOLDER_KEYS[*]}"
  fi
  if [[ "${#MISSING_KEYS[@]}" -eq 0 && "${#PLACEHOLDER_KEYS[@]}" -eq 0 ]]; then
    ok "every key in .env.example is set in .env"
  fi
fi

# Version pins the build depends on.
if [[ -f .env ]]; then
  ok "pins: $(grep -E '^(BIOMERO_VERSION|OMERO_BIOMERO_VERSION|BIOMERO_IMPORTER_VERSION)=' .env | tr '\n' ' ')"
else
  fail ".env is missing; copy .env.example to .env and fill it in"
fi

# The importer logs in to OMERO as OMERO_IMPORTER_USER. When that is root --
# which is what .env.example ships -- its password is root's password, and two
# different values leave it unable to log in. It then retries for five minutes
# and exits, nothing restarts it, and imports queued from the UI are silently
# never picked up. Cheap to check, expensive to diagnose.
IMP_USER="$(grep -hE '^OMERO_IMPORTER_USER=' .env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
IMP_PASS="$(grep -hE '^OMERO_IMPORTER_PASSWORD=' .env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
ROOT_PASS="$(grep -hE '^OMERO_ROOT_PASSWORD=' .env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
if [[ "${IMP_USER}" == "root" && -n "${IMP_PASS}" && "${IMP_PASS}" != "${ROOT_PASS}" ]]; then
  fail "OMERO_IMPORTER_USER is root but OMERO_IMPORTER_PASSWORD differs from OMERO_ROOT_PASSWORD"
  fail "  they are the same account, so the importer could not log in"
elif [[ "${IMP_USER}" == "root" ]]; then
  ok "importer credentials agree with the root account"
fi

# Spider identity and reachability. Non-fatal: the stack still starts without
# Slurm, it just cannot run workflows.
SPIDER_USER_VAL="$(grep -hE '^SPIDER_USER=' .env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
if [[ -n "${SPIDER_USER_VAL}" ]]; then
  ok "SPIDER_USER is set"
  # .ssh/config is biomeroworker's, and its ~ paths do not resolve here.
  SPIDER_SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 -o IdentitiesOnly=yes
              -i ".ssh/${SLURM_KEY_NAME}" -o UserKnownHostsFile=.ssh/known_hosts
              -o StrictHostKeyChecking=yes "${SPIDER_USER_VAL}@spider.surf.nl")
  if [[ ! -r ".ssh/${SLURM_KEY_NAME}" || ! -r .ssh/known_hosts ]]; then
    warn "host-side Spider SSH NOT TESTED: .ssh is inaccessible to this account"
  elif timeout 25 "${SPIDER_SSH[@]}" 'true' 2>/dev/null; then
    ok "Spider SSH reachable"
    if timeout 25 "${SPIDER_SSH[@]}" 'sinfo -h -o "%P"' 2>/dev/null | grep -q .; then
      ok "Spider Slurm responding to sinfo"
    else
      warn "Spider reachable but sinfo returned nothing"
    fi
  else
    warn "Spider SSH not reachable; stack will start but workflows cannot run"
    warn "  register the key on Spider: make show-key"
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
"${PROJECT_ROOT_DIR}/scripts/check-active-work.sh"

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
  echo "--check-only given; stopping before deployment."
  exit 0
fi

# --------------------------------------------------------------- deployment --
"${PROJECT_ROOT_DIR}/scripts/check-active-work.sh" --require-idle
echo
echo "== Deploying stack =="
"${PROJECT_ROOT_DIR}/scripts/deploy-local-stack.sh"

# Record what an empty volume was just initialised with, so a later deploy can
# detect a .env that has drifted from the data. A no-op on a stamped volume.
"${PROJECT_ROOT_DIR}/scripts/volume-identity.sh" write || true

if [[ "${SKIP_SMOKE}" -eq 1 ]]; then
  echo "--skip-smoke given; deployment finished without smoke tests."
  exit 0
fi

# Read-only smoke is also available independently as `make smoke`.
"${PROJECT_ROOT_DIR}/scripts/smoke-readonly.sh"
