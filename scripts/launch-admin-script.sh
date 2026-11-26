#!/usr/bin/env bash
# Launch an OMERO admin script, such as Slurm Init, without the browser.
#
# Logs in as the OMERO root user inside omeroserver, finds the script ID by its
# file name and launches it. Without inputs the script uses the browser form's
# defaults. ROOTPASS is set in the container from OMERO_ROOT_PASSWORD and is
# passed through the environment, never printed or put on a command line.
#
# Exit status 0 only means the launch ran: omero returns 0 even when the script
# fails or rejects its inputs, and ignores unknown input names. Read the
# script's Message output and any stderr block it prints.
#
# Usage:
#   scripts/launch-admin-script.sh SLURM_check_setup.py
#   scripts/launch-admin-script.sh SLURM_Init_environment.py 'Input name=value'
set -euo pipefail

PROJECT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT_DIR}"

[[ $# -ge 1 ]] || { echo "usage: $0 <script file name> [input=value ...]" >&2; exit 2; }

# Runs inside the container; the script file name and inputs arrive as $1 and on.
# omero login joins a saved session for the same user and server, and logout
# would end it, so this uses its own empty session directory, as in
# volume-identity.sh.
LAUNCH_IN_CONTAINER='
set -euo pipefail
OMERO=/opt/omero/server/venv3/bin/omero
script_file=$1; shift
session_dir=$(mktemp -d)
export OMERO_SESSIONDIR=$session_dir
trap "$OMERO logout >/dev/null 2>&1; rm -rf $session_dir" EXIT
OMERO_PASSWORD="$ROOTPASS" $OMERO login -s localhost -u root
matching_scripts=$($OMERO script list | grep -F "/${script_file}" || true)
match_count=$(printf "%s" "$matching_scripts" | grep -c . || true)
if [ "$match_count" -ne 1 ]; then
  echo "  [FAIL] expected one script named ${script_file}, found ${match_count}" >&2
  exit 1
fi
script_id=$(printf "%s" "$matching_scripts" | cut -d"|" -f1 | tr -d " ")
$OMERO script launch "$script_id" "$@"
'

sudo docker compose exec -T omeroserver bash -c "${LAUNCH_IN_CONTAINER}" launch-admin-script "$@"
