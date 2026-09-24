#!/usr/bin/env bash
# Inspect the newest nightly backup without restoring, decrypting, or writing.
set -euo pipefail
root=/data/surf-biomero-storage/backups/nightly
python3 scripts/check-storage-mount.py || exit 1
latest="$(sudo -n find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -1)"
if [[ -z "$latest" ]]; then echo 'NOT TESTED: no readable nightly backup directory'; exit 1; fi
backup="$root/$latest"
printf 'Backup: %s\n' "$backup"
if sudo -n test -f "$backup/COMPLETE"; then echo 'PASS: completion marker present'; else echo 'WARN: completion marker absent (older backup or interrupted run)'; fi
age_hours="$(( ($(date +%s) - $(sudo -n stat -c %Y "$backup")) / 3600 ))"
if (( age_hours <= 48 )); then echo "PASS: backup directory age ${age_hours}h"; else echo "WARN: backup directory age ${age_hours}h"; fi
for name in omero.pg_dump biomero.pg_dump metabase.pg_dump omero-files.tar.gz secrets.tar.gz SHA256SUMS; do
  if sudo -n test -s "$backup/$name"; then echo "PASS: $name present"; else echo "FAIL: $name missing or empty"; exit 1; fi
done
if sudo -n sh -c 'cd "$1" && sha256sum -c SHA256SUMS >/dev/null' sh "$backup"; then
  echo 'PASS: checksums match'
else
  echo 'FAIL: checksum verification failed'; exit 1
fi
for name in omero.pg_dump biomero.pg_dump metabase.pg_dump; do
  if sudo -n docker compose exec -T database pg_restore --list < <(sudo -n cat "$backup/$name") >/dev/null 2>&1; then
    echo "PASS: $name TOC readable"
  else
    echo "FAIL: $name TOC unreadable"; exit 1
  fi
done
for name in omero-files.tar.gz secrets.tar.gz; do
  if sudo -n tar -tzf "$backup/$name" >/dev/null 2>&1; then
    echo "PASS: $name archive readable"
  else
    echo "FAIL: $name archive unreadable"; exit 1
  fi
done
echo 'WARN: backup is on the same attached volume; off-host protection not verified'
echo 'NOT TESTED: restore consistency and recovery time'
