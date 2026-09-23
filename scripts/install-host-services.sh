#!/usr/bin/env bash
# Install the host units that make this a production deployment:
#
#   nl-biomero.service   starts the stack at boot and stops it at shutdown
#   nl-biomero-backup    runs scripts/backup-nightly.sh every night at 02:30
#
# Every compose service is RestartPolicy "no" on purpose: if Docker started the
# containers itself at boot, before the storage volume had mounted, Postgres
# would find an empty bind-mount directory and initdb a new cluster onto the
# root disk. The unit starts the stack only once the volume is mounted
# (RequiresMountsFor), which is what the restart policy could not guarantee.
#
# Safe to re-run: it rewrites the units from the current .env.
#
# Usage:
#   scripts/install-host-services.sh             install and enable both
#   scripts/install-host-services.sh --remove    disable and remove both
set -euo pipefail

PROJECT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT_DIR}"

UNIT_DIR=/etc/systemd/system
UNITS=(nl-biomero.service nl-biomero-backup.service nl-biomero-backup.timer)

if [[ "${1:-}" == "--remove" ]]; then
  sudo systemctl disable --now nl-biomero-backup.timer nl-biomero.service 2>/dev/null || true
  for u in "${UNITS[@]}"; do sudo rm -f "${UNIT_DIR}/${u}"; done
  sudo systemctl daemon-reload
  echo "removed ${UNITS[*]}"
  exit 0
fi

DATA_PATH="$(grep -hE '^OMERO_DATA_PATH=' .env | tail -1 | cut -d= -f2-)"
[[ -n "${DATA_PATH}" ]] || { echo "OMERO_DATA_PATH is not set in .env" >&2; exit 1; }

sudo tee "${UNIT_DIR}/nl-biomero.service" >/dev/null <<EOF
[Unit]
Description=NL-BIOMERO stack (docker compose)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target
RequiresMountsFor=${DATA_PATH}

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${PROJECT_ROOT_DIR}
ExecStart=/usr/bin/make up
ExecStop=/usr/bin/make down
TimeoutStartSec=15min
TimeoutStopSec=5min

[Install]
WantedBy=multi-user.target
EOF

sudo tee "${UNIT_DIR}/nl-biomero-backup.service" >/dev/null <<EOF
[Unit]
Description=NL-BIOMERO nightly backup
Requires=nl-biomero.service
After=nl-biomero.service
RequiresMountsFor=${DATA_PATH}

[Service]
Type=oneshot
WorkingDirectory=${PROJECT_ROOT_DIR}
ExecStart=${PROJECT_ROOT_DIR}/scripts/backup-nightly.sh
EOF

sudo tee "${UNIT_DIR}/nl-biomero-backup.timer" >/dev/null <<EOF
[Unit]
Description=NL-BIOMERO nightly backup

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
# Start as well as enable: `make up` on a running stack changes nothing, and an
# inactive unit would skip `make down` at shutdown.
sudo systemctl enable --now nl-biomero.service >/dev/null
sudo systemctl enable --now nl-biomero-backup.timer >/dev/null

echo "installed ${UNITS[*]}"
echo "  stack starts at boot once ${DATA_PATH} is mounted"
echo "  next backup: $(systemctl list-timers nl-biomero-backup.timer --no-legend | awk '{print $1, $2, $3}')"
