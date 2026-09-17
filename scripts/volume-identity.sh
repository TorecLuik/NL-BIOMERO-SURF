#!/usr/bin/env bash
# The database credentials a storage volume was initialised with.
#
# Postgres seeds POSTGRES_PASSWORD into the cluster the first time it starts
# and ignores it on every start after that. The password in .env is therefore
# authoritative exactly once, when the volume is empty; from then on the truth
# lives in the data. A .env that disagrees is not rejected at startup -- the
# containers come up and then fail to authenticate.
#
# So the deployment records what it initialised the volume with, in
# <volume>/config/volume-identity, and compares on every later deploy. The file
# holds salted hashes, never the passwords: it exists to detect drift, not to
# reveal or restore a credential.
#
# It is never an input to compose. Compose reads .env and only .env; this file
# can agree with it or stop the deployment, but it cannot quietly supply a
# value.
#
# Usage:
#   volume-identity.sh check    compare .env against the volume, if stamped
#   volume-identity.sh write    record the current .env (empty volume only)
#   volume-identity.sh adopt    stamp a populated volume, verifying first
set -euo pipefail

PROJECT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT_DIR}"

STAMPED_KEYS=(POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD
              BIOMERO_POSTGRES_USER BIOMERO_POSTGRES_DB BIOMERO_POSTGRES_PASSWORD)

env_value() { grep -hE "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true; }

data_path() {
  local p
  p="$(env_value OMERO_DATA_PATH)"
  [[ -n "${p}" ]] || { echo "OMERO_DATA_PATH is not set in .env" >&2; exit 1; }
  printf '%s' "${p}"
}

# Salted so the file does not become an offline dictionary target. The salt sits
# beside the hashes: it defends a weak password against a stolen file, not
# against someone who can already read the volume.
#
# The key name is part of the input, so two settings that happen to share a
# value -- POSTGRES_USER, _DB and _PASSWORD are all "omero" by default -- do not
# produce the same hash and advertise that they match.
hash_value() { printf '%s\n%s\n%s' "$1" "$2" "$3" | sha256sum | cut -d' ' -f1; }

stamp_path() { printf '%s/config/volume-identity' "$(data_path)"; }

# A volume is "populated" once Postgres has initialised a cluster in it.
volume_has_data() { sudo test -s "$(data_path)/database/PG_VERSION"; }

read_stamp_field() { sudo grep -hE "^$1=" "$(stamp_path)" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

write_stamp() {
  local path salt tmp
  path="$(stamp_path)"
  salt="$(openssl rand -hex 16)"
  tmp="$(mktemp)"
  {
    echo "# Database credentials this volume was initialised with."
    echo "# Hashes, not passwords. Written by scripts/volume-identity.sh."
    echo "# Deleting this file only disables drift detection."
    echo "stamped_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "salt=${salt}"
    for key in "${STAMPED_KEYS[@]}"; do
      echo "${key}=$(hash_value "${key}" "$(env_value "${key}")" "${salt}")"
    done
  } > "${tmp}"
  sudo mkdir -p "$(dirname "${path}")"
  sudo cp "${tmp}" "${path}"
  sudo chmod 0644 "${path}"
  rm -f "${tmp}"
  echo "  [ ok ] recorded database identity in ${path}"
}

# Every stamped key must still hash to what the volume recorded.
compare_stamp() {
  local salt drift=() key
  salt="$(read_stamp_field salt)"
  if [[ -z "${salt}" ]]; then
    echo "  [FAIL] $(stamp_path) has no salt; it is corrupt" >&2
    return 1
  fi
  for key in "${STAMPED_KEYS[@]}"; do
    local recorded current
    recorded="$(read_stamp_field "${key}")"
    [[ -n "${recorded}" ]] || continue
    current="$(hash_value "${key}" "$(env_value "${key}")" "${salt}")"
    [[ "${recorded}" == "${current}" ]] || drift+=("${key}")
  done
  if [[ "${#drift[@]}" -gt 0 ]]; then
    echo "  [FAIL] .env disagrees with the volume on: ${drift[*]}" >&2
    echo "         These are fixed by the data in $(data_path)/database." >&2
    echo "         Correct .env to match; the volume cannot adopt a new password." >&2
    return 1
  fi
  echo "  [ ok ] database credentials match the volume"
  return 0
}

# Prove a password before trusting it. pg_hba trusts local connections, so
# `docker compose exec psql` succeeds whatever the password is -- only a TCP
# connection from outside the container actually authenticates.
verify_live_password() {
  local user db pass cid
  user="$(env_value POSTGRES_USER)"
  db="$(env_value POSTGRES_DB)"
  pass="$(env_value POSTGRES_PASSWORD)"
  cid="$(sudo docker compose ps -q database 2>/dev/null | head -1)"
  if [[ -z "${cid}" ]]; then
    echo "  [FAIL] the database container is not running; start it with: make up" >&2
    return 1
  fi
  # pg_hba matches the first rule that fits, and both "local" and 127.0.0.1 are
  # trusted -- so `compose exec psql` and any loopback connection succeed
  # whatever the password is. Only a connection from another address falls
  # through to the scram-sha-256 rule and actually proves the credential.
  local addr
  addr="$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${cid}" | awk '{print $1}')"
  if [[ -z "${addr}" ]]; then
    echo "  [FAIL] could not resolve the database container address" >&2
    return 1
  fi
  sudo docker run --rm --network "$(sudo docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' "${cid}" | head -1)" \
      -e PGPASSWORD="${pass}" postgres:16 \
      psql -h "${addr}" -U "${user}" -d "${db}" -c 'SELECT 1' >/dev/null 2>&1
}

case "${1:-check}" in
  check)
    if ! volume_has_data; then
      echo "  [ ok ] volume is empty; .env will initialise it"
      exit 0
    fi
    if ! sudo test -f "$(stamp_path)"; then
      echo "  [warn] this volume holds data but was never stamped"
      echo "         Credential drift cannot be detected until it is:"
      echo "           make adopt-volume"
      exit 0
    fi
    compare_stamp
    ;;
  write)
    if volume_has_data && sudo test -f "$(stamp_path)"; then
      echo "  [ ok ] volume already stamped"
      exit 0
    fi
    write_stamp
    ;;
  adopt)
    if ! volume_has_data; then
      echo "  [FAIL] this volume holds no database; nothing to adopt." >&2
      echo "         Deploy normally and the stamp is written for you." >&2
      exit 1
    fi
    if sudo test -f "$(stamp_path)"; then
      echo "  [ ok ] already stamped; nothing to do"
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
