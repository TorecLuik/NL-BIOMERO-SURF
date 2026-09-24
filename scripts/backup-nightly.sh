#!/usr/bin/env bash
# Nightly backup of everything this deployment cannot rebuild from git.
#
# Writes one timestamped directory under <volume>/backups/nightly/ holding:
#
#   omero.pg_dump, biomero.pg_dump, metabase.pg_dump   custom-format dumps,
#                                                      taken from the running
#                                                      databases, so no downtime
#   omero-files.tar.gz     the OMERO binary repository, without the caches
#   secrets.tar.gz         .env, .ssh/, config/volume-identity, the web configs:
#                          what unlocks the volume and reaches the cluster
#   SHA256SUMS
#
# L-Drive is not included: it is the users' raw data, too large to copy nightly,
# and it is the part the storage volume itself exists to keep.
#
# The dumps live on the same volume as the databases, so they protect against
# a bad upgrade or a deleted project, not against losing the volume. Copy them
# off the VM for that; see deployment_docs/runbook.md.
#
# Usage:
#   scripts/backup-nightly.sh               write one complete backup set
#   Retention deletion requires separate explicit authorization.
set -euo pipefail

PROJECT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT_DIR}"

COMPOSE=(docker compose)
[[ "$(id -u)" -eq 0 ]] || COMPOSE=(sudo docker compose)

env_value() { grep -hE "^$1=" .env | tail -1 | cut -d= -f2-; }

python3 scripts/check-storage-mount.py
DATA_PATH="$(env_value OMERO_DATA_PATH)"
[[ -d "${DATA_PATH}/omero" ]] || { echo "no ${DATA_PATH}/omero; is the volume attached?" >&2; exit 1; }

DEST_ROOT="${DATA_PATH}/backups/nightly"
DEST="${DEST_ROOT}/$(date +%Y%m%d-%H%M%S)"
# Dumps carry every user's metadata and secrets.tar.gz the database passwords,
# so the directory is root-only, whatever umask cron runs with.
sudo install -d -m 700 -o root -g root "${DEST_ROOT}" "${DEST}"

dump() {
  local svc="$1" user="$2" db="$3" out="$4"
  "${COMPOSE[@]}" exec -T "${svc}" pg_dump -U "${user}" -Fc "${db}" | sudo tee "${DEST}/${out}" >/dev/null
  sudo test -s "${DEST}/${out}" || { echo "empty dump: ${out}" >&2; exit 1; }
}

dump database         "$(env_value POSTGRES_USER)"         "$(env_value POSTGRES_DB)"         omero.pg_dump
dump database-biomero "$(env_value BIOMERO_POSTGRES_USER)" "$(env_value BIOMERO_POSTGRES_DB)" biomero.pg_dump
# Metabase keeps its application database in the BIOMERO cluster.
dump database-biomero "$(env_value BIOMERO_POSTGRES_USER)" metabase                           metabase.pg_dump

# The repository's symlinks point into L-Drive; tar keeps them as links.
sudo tar -C "${DATA_PATH}" -czf "${DEST}/omero-files.tar.gz" \
  --exclude=omero/BioFormatsCache --exclude=omero/FullText omero

sudo tar -C "${PROJECT_ROOT_DIR}" -czf "${DEST}/secrets.tar.gz" \
  .env .ssh web/slurm-config.ini web/biomero-config.json \
  -C "${DATA_PATH}" config

sudo sh -c "cd '${DEST}' && sha256sum *.pg_dump *.tar.gz > SHA256SUMS"
sudo touch "${DEST}/COMPLETE"

echo "backup written to ${DEST} ($(sudo du -sh "${DEST}" | cut -f1))"
