#!/usr/bin/env bash
# Create .env from .env.example, generating every secret that is only entropy.
#
# Of the values .env.example marks CHANGE ME, exactly two carry meaning outside
# this VM: SPIDER_USER and SPIDER_PROJECT, which name a cluster account someone
# granted. The rest are passwords and keys whose only requirement is that they
# are unguessable and that the same string reaches every service that needs it.
# A human typing those adds no information -- only the chance of a weak or
# mistyped one -- so they are generated here.
#
# This writes .env and nothing else. It refuses to touch an existing one: on a
# volume that already holds data the database passwords are fixed by that data,
# and regenerating them would lock the stack out of its own databases.
#
# Usage:
#   scripts/init-env.sh                      prompt for the two cluster values
#   scripts/init-env.sh --user U --project P non-interactive
#   scripts/init-env.sh --force              replace an existing .env
set -euo pipefail

PROJECT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT_DIR}"

ENV_PATH=".env"
EXAMPLE_PATH=".env.example"
SPIDER_USER_IN=""
SPIDER_PROJECT_IN=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)    SPIDER_USER_IN="${2:-}"; shift 2 ;;
    --project) SPIDER_PROJECT_IN="${2:-}"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "${EXAMPLE_PATH}" ]]; then
  echo "Missing ${EXAMPLE_PATH}" >&2
  exit 1
fi

if [[ -e "${ENV_PATH}" && "${FORCE}" -ne 1 ]]; then
  echo "${ENV_PATH} already exists." >&2
  echo >&2
  echo "Its database passwords may be the only record of what unlocks the" >&2
  echo "storage volume, so this refuses to overwrite it." >&2
  echo >&2
  echo "  scripts/init-env.sh --force    replace it anyway" >&2
  exit 1
fi

# Alphanumeric only: these travel through URLs, .pgpass, htpasswd and compose
# interpolation, and every one of those has its own quoting or $-expansion
# rules. Length, not punctuation, is what makes them hard to guess.
#
# Read a bounded amount and trim, rather than piping /dev/urandom into head:
# head exits at its byte count and SIGPIPEs tr, which under `set -o pipefail`
# fails the whole script with 141.
gen() {
  local n="${1:-32}"
  LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c $(( n * 8 )) /dev/urandom) | cut -c1-"${n}"
}

if [[ -z "${SPIDER_USER_IN}" ]]; then
  read -rp "Spider username (the cluster account, e.g. biomero-jdoe): " SPIDER_USER_IN
fi
if [[ -z "${SPIDER_PROJECT_IN}" ]]; then
  read -rp "Spider project [biomero]: " SPIDER_PROJECT_IN
  SPIDER_PROJECT_IN="${SPIDER_PROJECT_IN:-biomero}"
fi
if [[ -z "${SPIDER_USER_IN}" || -z "${SPIDER_PROJECT_IN}" ]]; then
  echo "SPIDER_USER and SPIDER_PROJECT are both required." >&2
  exit 1
fi

# The volume directory takes its name from the portal volume, so it differs per
# VM. Use the one that is actually mounted rather than the example's default.
MOUNTED_VOL="$(awk '$2 ~ "^/data/" {print $2}' /proc/mounts | head -1)"

# OMERO_IMPORTER_USER ships as root, so the importer's password is root's
# password. Generating two different strings leaves the importer unable to log
# in, and it exits after five minutes of retries rather than failing loudly.
OMERO_ROOT_PASSWORD_VAL="$(gen 32)"

# Metabase requires an email-shaped admin login and rejects a bare word.
declare -A VALUES=(
  [SPIDER_USER]="${SPIDER_USER_IN}"
  [SPIDER_PROJECT]="${SPIDER_PROJECT_IN}"
  [POSTGRES_PASSWORD]="$(gen 32)"
  [BIOMERO_POSTGRES_PASSWORD]="$(gen 32)"
  [OMERO_ROOT_PASSWORD]="${OMERO_ROOT_PASSWORD_VAL}"
  [OMERO_IMPORTER_PASSWORD]="${OMERO_ROOT_PASSWORD_VAL}"
  [METABASE_USER]="admin@${SPIDER_PROJECT_IN}.local"
  [METABASE_PASSWORD]="$(gen 24)"
  [FORMS_MASTER_USER]="formsadmin"
  [FORMS_MASTER_PASSWORD]="$(gen 32)"
  [METABASE_SECRET_KEY]="$(openssl rand -hex 32)"
  [NGINX_LOGS_PASSWORD]="$(gen 24)"
)
if [[ -n "${MOUNTED_VOL}" ]]; then
  VALUES[OMERO_DATA_PATH]="${MOUNTED_VOL}"
fi

# A volume that already carries its credentials decides the values its data
# fixes. Generating them here would only produce a .env that disagrees with the
# volume, so leave them unset: `make deploy` fills them from the volume. The
# importer's password follows root's, so it is left unset with it.
FROM_VOLUME=()
if [[ -n "${MOUNTED_VOL}" ]] && sudo test -f "${MOUNTED_VOL}/config/volume-identity"; then
  while IFS= read -r key; do
    # An explicit placeholder rather than skipping the key: .env.example gives
    # some of these real defaults, which would then read as a disagreement.
    if grep -qE "^${key}=" "${EXAMPLE_PATH}"; then
      VALUES[${key}]="CHANGE ME"
      FROM_VOLUME+=("${key}")
    fi
  done < <(./scripts/volume-identity.sh keys)
  if [[ " ${FROM_VOLUME[*]} " == *" OMERO_ROOT_PASSWORD "* ]]; then
    VALUES[OMERO_IMPORTER_PASSWORD]="CHANGE ME"
    FROM_VOLUME+=(OMERO_IMPORTER_PASSWORD)
  fi
fi

# Hand the values over as NUL-delimited KEY=VALUE pairs on stdin, so no value
# has to survive a second round of shell quoting on its way into python.
for key in "${!VALUES[@]}"; do
  printf '%s=%s\0' "${key}" "${VALUES[${key}]}"
done | FROM_VOLUME="${FROM_VOLUME[*]}" python3 -c '
import re, sys

example_path, env_path = sys.argv[1], sys.argv[2]

values = {}
for pair in sys.stdin.buffer.read().split(b"\0"):
    if not pair:
        continue
    key, _, val = pair.decode().partition("=")
    values[key] = val

out, seen = [], set()
for line in open(example_path).read().split("\n"):
    m = re.match(r"^([A-Z0-9_]+)=", line)
    if m and m.group(1) in values:
        out.append(f"{m.group(1)}={values[m.group(1)]}")
        seen.add(m.group(1))
    else:
        out.append(line)

open(env_path, "w").write("\n".join(out))

missing = sorted(k for k in values if k not in seen)
if missing:
    sys.exit("init-env: not present in .env.example: " + ", ".join(missing))

import os
from_volume = set(os.environ.get("FROM_VOLUME", "").split())
leftover = [l.split("=")[0] for l in out
            if not l.startswith("#") and l.endswith("CHANGE ME")
            and l.split("=")[0] not in from_volume]
if leftover:
    sys.exit("init-env: still unset after generating: " + ", ".join(leftover))
' "${EXAMPLE_PATH}" "${ENV_PATH}"

chmod 600 "${ENV_PATH}"
if [[ "${#FROM_VOLUME[@]}" -gt 0 ]]; then
  echo "This volume already carries its credentials; left unset for make deploy"
  echo "to fill from it: ${FROM_VOLUME[*]}"
fi
echo "Wrote ${ENV_PATH} (mode 0600), with ${#VALUES[@]} values filled in."
echo
echo "It is the only copy of these secrets, and the database passwords are what"
echo "unlock the storage volume. Archive it somewhere off this VM."
