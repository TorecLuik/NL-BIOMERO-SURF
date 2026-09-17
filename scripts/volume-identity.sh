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
#   volume-identity.sh adopt    record a populated volume, verifying first
set -euo pipefail

PROJECT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT_DIR}"

# Fixed by the volume's data: the databases cannot be opened without them.
# METABASE_SECRET_KEY belongs here too -- it decrypts secrets Metabase has
# already written into its application database.
VOLUME_KEYS=(POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD
             BIOMERO_POSTGRES_USER BIOMERO_POSTGRES_DB BIOMERO_POSTGRES_PASSWORD
             METABASE_SECRET_KEY)

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
verify_live_password() {
  local user db pass cid net addr
  user="$(env_value POSTGRES_USER)"
  db="$(env_value POSTGRES_DB)"
  pass="$(env_value POSTGRES_PASSWORD)"
  cid="$(sudo docker compose ps -q database 2>/dev/null | head -1)"
  if [[ -z "${cid}" ]]; then
    echo "  [FAIL] the database container is not running; start it with: make up" >&2
    return 1
  fi
  addr="$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${cid}" | awk '{print $1}')"
  net="$(sudo docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "${cid}" | awk '{print $1}')"
  if [[ -z "${addr}" || -z "${net}" ]]; then
    echo "  [FAIL] could not resolve the database container address" >&2
    return 1
  fi
  sudo docker run --rm --network "${net}" -e PGPASSWORD="${pass}" postgres:16 \
      psql -h "${addr}" -U "${user}" -d "${db}" -c 'SELECT 1' >/dev/null 2>&1
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
      echo "  [ ok ] already recorded; nothing to do"
      exit 0
    fi
    echo "  verifying POSTGRES_PASSWORD against the running database..."
    if ! verify_live_password; then
      echo "  [FAIL] the password in .env is not the one this volume was built with." >&2
      echo "         Nothing was written. Find the working password and retry." >&2
      exit 1
    fi
    echo "  [ ok ] the password in .env authenticates"
    write_stamp
    ;;
  *)
    echo "usage: volume-identity.sh [check|write|adopt]" >&2
    exit 2
    ;;
esac
