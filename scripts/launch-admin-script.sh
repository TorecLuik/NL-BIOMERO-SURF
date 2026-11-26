#!/usr/bin/env bash
# Launch an OMERO admin script, such as Slurm Init, without the browser.
#
# Logs in as root inside omeroserver, finds the script ID by its file name and
# launches it. Without inputs the script uses the browser form's defaults.
# ROOTPASS is set in the container from OMERO_ROOT_PASSWORD and is never printed.
#
# Usage:
#   scripts/launch-admin-script.sh SLURM_check_setup.py
#   scripts/launch-admin-script.sh SLURM_Init_environment.py 'Input name=value'
set -euo pipefail

PROJECT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT_DIR}"

[[ $# -ge 1 ]] || { echo "usage: $0 <script file name> [input=value ...]" >&2; exit 2; }

# Runs inside the container; the script file name and inputs arrive as $1 and on.
LAUNCH_IN_CONTAINER='
set -euo pipefail
script_file=$1; shift
omero login -s localhost -u root -w "$ROOTPASS"
trap "omero logout >/dev/null 2>&1" EXIT
matching_scripts=$(omero script list | grep -F "/${script_file}" || true)
match_count=$(printf "%s" "$matching_scripts" | grep -c . || true)
if [ "$match_count" -ne 1 ]; then
  echo "  [FAIL] expected one script named ${script_file}, found ${match_count}" >&2
  exit 1
fi
script_id=$(printf "%s" "$matching_scripts" | cut -d"|" -f1 | tr -d " ")
omero script launch "$script_id" "$@"
'

sudo docker compose exec -T omeroserver bash -lc "${LAUNCH_IN_CONTAINER}" launch-admin-script "$@"
