#!/usr/bin/env bash
# The credentials that unlock a storage volume's data, kept with that volume.
#
# Postgres seeds POSTGRES_PASSWORD into the cluster the first time it starts and
# ignores it afterwards, so these values are decided once, when the volume is
# empty, and are fixed by the data from then on. They open that volume and
# nothing else, and without them its databases cannot be read at all.
#
# So they live on the volume, in <volume>/config/volume-identity, and a VM that
# attaches it gets them from there. .env carries what belongs to the VM --
# hostnames, cluster identity, generated secrets -- and nothing that a
# reattached volume would need supplied back to it.
#
# Compose still reads .env alone. This file fills a missing value in before the
# stack starts and refuses to continue when the two disagree, but it is never a
# second source compose consults.
#
# Usage:
#   volume-identity.sh check    fill .env from the volume, or report a conflict
#   volume-identity.sh write    record the current .env (empty volume only)
#   volume-identity.sh adopt    record a populated volume, verifying first; on
#                               a volume already recorded, add any key its
#                               record lacks
#   volume-identity.sh keys     list the keys the volume fixes
#   volume-identity.sh rotate KEY   change POSTGRES_PASSWORD or
#                                   BIOMERO_POSTGRES_PASSWORD in the database,
#                                   .env and the volume together
set -euo pipefail

PROJECT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT_DIR}"

# Fixed by the volume's data: each is read once, when the thing it protects is
# first created, and ignored afterwards.
#
#   POSTGRES_* / BIOMERO_POSTGRES_*   the databases cannot be opened without them
#   METABASE_SECRET_KEY               decrypts what Metabase has already stored
#   OMERO_ROOT_PASSWORD               ROOTPASS only applies at `omego db init`
#   FORMS_MASTER_USER                 owns the existing forms; its password is
#                                     not listed, OMERO.web resets it from root
#   METABASE_USER / _PASSWORD         Metabase's first-setup admin, stored in its
#                                     application database
#
# A key an older record lacks is simply not checked; `adopt` adds it.
VOLUME_KEYS=(POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD
             BIOMERO_POSTGRES_USER BIOMERO_POSTGRES_DB BIOMERO_POSTGRES_PASSWORD
             METABASE_SECRET_KEY
             OMERO_ROOT_PASSWORD FORMS_MASTER_USER
             METABASE_USER METABASE_PASSWORD)

env_value() { grep -hE "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true; }

data_path() {
  local p
  p="$(env_value OMERO_DATA_PATH)"
  [[ -n "${p}" ]] || { echo "OMERO_DATA_PATH is not set in .env" >&2; exit 1; }
  printf '%s' "${p}"
}

stamp_path() { printf '%s/config/volume-identity' "$(data_path)"; }

# A volume is populated once Postgres has initialised a cluster in it.
volume_has_data() { sudo test -s "$(data_path)/database/PG_VERSION"; }

stamp_value() { sudo grep -hE "^$1=" "$(stamp_path)" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

# Written 0600 and owned by the login user: it sits beside the database files it
# opens, so it is no more exposed than they are, but it should not be world
# readable on a shared mount.
write_stamp() {
  local path tmp key value
  path="$(stamp_path)"
  tmp="$(mktemp)"
  {
    echo "# Credentials that unlock this volume's data."
    echo "# Written by scripts/volume-identity.sh. Keep this with the volume:"
    echo "# without it the databases here cannot be opened."
    echo "written_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for key in "${VOLUME_KEYS[@]}"; do
      value="$(env_value "${key}")"
      [[ -n "${value}" ]] && echo "${key}=${value}"
    done
  } > "${tmp}"
  sudo mkdir -p "$(dirname "${path}")"
  sudo cp "${tmp}" "${path}"
  sudo chmod 0600 "${path}"
  sudo chown "$(id -u):$(id -g)" "${path}"
  rm -f "${tmp}"
  echo "  [ ok ] recorded the volume's credentials in ${path}"
}

# Append a value .env is missing. This is the reattach case: a fresh .env from
# .env.example has placeholders where the volume has the real values.
fill_env() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" .env 2>/dev/null; then
    # A placeholder or empty value is replaced in place; a real one never is.
    python3 - "$key" "$value" <<'PY'
import sys, re
key, value = sys.argv[1], sys.argv[2]
lines = open('.env').read().split('\n')
for i, line in enumerate(lines):
    if line.startswith(key + '='):
        lines[i] = f'{key}={value}'
        break
open('.env', 'w').write('\n'.join(lines))
PY
  else
    printf '%s=%s\n' "${key}" "${value}" >> .env
  fi
}

needs_value() {
  local current="$1"
  [[ -z "${current}" || "${current}" == *"CHANGE ME"* || "${current}" == *"CHANGE-ME"* ]]
}

# Prove a password before recording it. pg_hba matches the first rule that fits,
# and both "local" and 127.0.0.1 are trusted, so `compose exec psql` succeeds
# whatever the password is. Only a connection from another address reaches the
# scram-sha-256 rule and actually authenticates.
# pg_hba matches the first rule that fits, and both "local" and 127.0.0.1 are
# trusted, so `compose exec psql` succeeds whatever the password is. Only a
# connection from another address reaches the scram-sha-256 rule and actually
# authenticates -- which is how the other containers connect.
password_authenticates() {
  local svc="$1" user="$2" db="$3" pass="$4" cid net addr
  cid="$(sudo docker compose ps -q "${svc}" 2>/dev/null | head -1)"
  if [[ -z "${cid}" ]]; then
    echo "  [FAIL] ${svc} is not running; start it with: make up" >&2
    return 2
  fi
  addr="$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${cid}" | awk '{print $1}')"
  net="$(sudo docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "${cid}" | awk '{print $1}')"
  if [[ -z "${addr}" || -z "${net}" ]]; then
    echo "  [FAIL] could not resolve the ${svc} container address" >&2
    return 2
  fi
  sudo docker run --rm --network "${net}" -e PGPASSWORD="${pass}" postgres:16 \
      psql -h "${addr}" -U "${user}" -d "${db}" -c 'SELECT 1' >/dev/null 2>&1
}

verify_live_password() {
  password_authenticates database "$(env_value POSTGRES_USER)" \
    "$(env_value POSTGRES_DB)" "$(env_value POSTGRES_PASSWORD)"
}

# The recorded values that are not Postgres passwords are checked against the
# running services that hold them, so adopt cannot record a wrong one.
omero_login_ok() {
  sudo docker compose exec -T -e U="$1" -e P="$2" omeroserver sh -c \
    '/opt/omero/server/venv3/bin/omero login -s localhost -u "$U" -w "$P" -q >/dev/null 2>&1 \
     && /opt/omero/server/venv3/bin/omero logout -q >/dev/null 2>&1'
}

omero_user_exists() {
  local n
  n="$(sudo docker compose exec -T database psql -U "$(env_value POSTGRES_USER)" \
        -d "$(env_value POSTGRES_DB)" -tAc \
        "SELECT count(*) FROM experimenter WHERE omename = '$1'" 2>/dev/null | tr -d '[:space:]')"
  [[ "${n}" == "1" ]]
}

metabase_login_ok() {
  python3 - "$1" "$2" <<'PY'
import json, sys, urllib.request
req = urllib.request.Request("http://localhost:3000/api/session",
    data=json.dumps({"username": sys.argv[1], "password": sys.argv[2]}).encode(),
    headers={"Content-Type": "application/json"})
try:
    sys.exit(0 if "id" in json.load(urllib.request.urlopen(req, timeout=20)) else 1)
except Exception:
    sys.exit(1)
PY
}

verify_key() {
  local key="$1" value
  value="$(env_value "${key}")"
  case "${key}" in
    POSTGRES_PASSWORD) verify_live_password ;;
    BIOMERO_POSTGRES_PASSWORD)
      password_authenticates database-biomero "$(env_value BIOMERO_POSTGRES_USER)" \
        "$(env_value BIOMERO_POSTGRES_DB)" "${value}" ;;
    OMERO_ROOT_PASSWORD) omero_login_ok root "${value}" ;;
    FORMS_MASTER_USER)   omero_user_exists "${value}" ;;
    METABASE_PASSWORD)   metabase_login_ok "$(env_value METABASE_USER)" "${value}" ;;
    *) return 0 ;;   # names, and METABASE_SECRET_KEY, which has no probe
  esac
}

gen_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 256 /dev/urandom) | cut -c1-32
}

case "${1:-check}" in
  check)
    if ! volume_has_data; then
      echo "  [ ok ] volume is empty; .env will initialise it"
      exit 0
    fi
    if ! sudo test -f "$(stamp_path)"; then
      echo "  [warn] this volume holds data but carries no credentials"
      echo "         Record them so a future VM can open it:"
      echo "           make adopt-volume"
      exit 0
    fi
    filled=()
    drift=()
    for key in "${VOLUME_KEYS[@]}"; do
      recorded="$(stamp_value "${key}")"
      [[ -n "${recorded}" ]] || continue
      current="$(env_value "${key}")"
      if needs_value "${current}"; then
        fill_env "${key}" "${recorded}"
        filled+=("${key}")
      elif [[ "${current}" != "${recorded}" ]]; then
        drift+=("${key}")
      fi
    done
    # The importer logs in as OMERO_IMPORTER_USER; as root, that is root's
    # password, so it follows the volume's root password rather than drifting.
    if [[ "$(env_value OMERO_IMPORTER_USER)" == "root" ]] \
       && needs_value "$(env_value OMERO_IMPORTER_PASSWORD)" \
       && [[ -n "$(stamp_value OMERO_ROOT_PASSWORD)" ]]; then
      fill_env OMERO_IMPORTER_PASSWORD "$(stamp_value OMERO_ROOT_PASSWORD)"
      filled+=(OMERO_IMPORTER_PASSWORD)
    fi
    if [[ "${#drift[@]}" -gt 0 ]]; then
      echo "  [FAIL] .env disagrees with the volume on: ${drift[*]}" >&2
      echo "         The volume's values are fixed by its data. Remove these from" >&2
      echo "         .env to take the volume's, or attach the matching volume." >&2
      exit 1
    fi
    if [[ "${#filled[@]}" -gt 0 ]]; then
      echo "  [ ok ] took from the volume: ${filled[*]}"
    else
      echo "  [ ok ] .env matches the volume"
    fi
    ;;
  write)
    if volume_has_data && sudo test -f "$(stamp_path)"; then
      echo "  [ ok ] volume already carries its credentials"
      exit 0
    fi
    write_stamp
    ;;
  adopt)
    if ! volume_has_data; then
      echo "  [FAIL] this volume holds no database; nothing to adopt." >&2
      echo "         Deploy normally and the credentials are recorded for you." >&2
      exit 1
    fi
    if sudo test -f "$(stamp_path)"; then
      # Extend an older record. The keys it has must agree with .env, which
      # check enforces; the ones it lacks are verified before being added.
      "${PROJECT_ROOT_DIR}/scripts/volume-identity.sh" check || exit 1
      to_add=()
      for key in "${VOLUME_KEYS[@]}"; do
        [[ -n "$(stamp_value "${key}")" ]] || to_add+=("${key}")
      done
      if [[ "${#to_add[@]}" -eq 0 ]]; then
        echo "  [ ok ] already recorded; nothing to do"
        exit 0
      fi
    else
      to_add=("${VOLUME_KEYS[@]}")
    fi
    for key in "${to_add[@]}"; do
      if needs_value "$(env_value "${key}")"; then
        echo "  [FAIL] ${key} is not set in .env; set it to this volume's value." >&2
        exit 1
      fi
      if ! verify_key "${key}"; then
        echo "  [FAIL] ${key} in .env does not match what this volume's services hold." >&2
        echo "         Nothing was written. Find the working value and retry." >&2
        exit 1
      fi
      echo "  [ ok ] ${key} verified"
    done
    write_stamp
    ;;
  rotate)
    # The password lives in three places that must change together: the
    # cluster, .env, and the volume's record. The other containers read it
    # from .env at start, and Metabase keeps its own copy for its datasource.
    key="${2:-}"
    case "${key}" in
      POSTGRES_PASSWORD)         svc=database;         ukey=POSTGRES_USER;         dkey=POSTGRES_DB ;;
      BIOMERO_POSTGRES_PASSWORD) svc=database-biomero; ukey=BIOMERO_POSTGRES_USER; dkey=BIOMERO_POSTGRES_DB ;;
      *) echo "usage: volume-identity.sh rotate POSTGRES_PASSWORD|BIOMERO_POSTGRES_PASSWORD" >&2; exit 2 ;;
    esac
    user="$(env_value "${ukey}")"; db="$(env_value "${dkey}")"; old="$(env_value "${key}")"
    password_authenticates "${svc}" "${user}" "${db}" "${old}" || {
      echo "  [FAIL] the current ${key} in .env does not authenticate; fix that first." >&2
      exit 1
    }
    new="$(gen_password)"
    # Over stdin, so the new password never appears in a process list.
    printf "ALTER USER \"%s\" PASSWORD '%s';\n" "${user}" "${new}" \
      | sudo docker compose exec -T "${svc}" psql -U "${user}" -d "${db}" -q -v ON_ERROR_STOP=1
    fill_env "${key}" "${new}"
    write_stamp
    if password_authenticates "${svc}" "${user}" "${db}" "${new}" \
       && ! password_authenticates "${svc}" "${user}" "${db}" "${old}"; then
      echo "  [ ok ] ${key} rotated: the new one authenticates, the old one no longer does"
    else
      echo "  [FAIL] rotation did not take; check ${svc} by hand" >&2
      exit 1
    fi
    echo "  next: make up   (containers read it from .env at start)"
    echo "        scripts/restore-metabase-dashboards.sh   (updates Metabase's copy)"
    ;;
  keys)
    printf '%s\n' "${VOLUME_KEYS[@]}"
    ;;
  *)
    echo "usage: volume-identity.sh [check|write|adopt|rotate KEY|keys]" >&2
    exit 2
    ;;
esac
