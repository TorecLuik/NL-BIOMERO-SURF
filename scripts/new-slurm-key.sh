#!/usr/bin/env bash
# Generate the SSH key this deployment uses to reach the Slurm cluster.
#
# The key is deliberately separate from whatever key this VM uses for its git
# remote. That one is a disposable per-VM credential; this one represents an
# authorisation granted on the cluster, so it outlives the VM, is handed to
# other people, and is revoked deliberately rather than by rebuilding a machine.
# It covers every cluster host in .ssh/config, not Spider alone.
#
# Generating a key does not grant access. The public half has to be registered
# on the cluster for SPIDER_USER before the stack can run workflows.
#
# The filename comes from SLURM_ACCESS_KEY in .env, defaulting to
# slurm_access_key.
#
# Usage:
#   scripts/new-slurm-key.sh            generate, refusing to replace one
#   scripts/new-slurm-key.sh --force    replace the existing key
#   scripts/new-slurm-key.sh --show     print the public half of the current key
set -euo pipefail

PROJECT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT_DIR}"

SSH_DIR="${PROJECT_ROOT_DIR}/.ssh"
KEY_NAME="$(grep -hE '^SLURM_ACCESS_KEY=' .env 2>/dev/null | tail -1 | cut -d= -f2-)"
KEY_NAME="${KEY_NAME:-slurm_access_key}"
KEY="${SSH_DIR}/${KEY_NAME}"

FORCE=0
SHOW=0
for arg in "$@"; do
  case "${arg}" in
    --force) FORCE=1 ;;
    --show)  SHOW=1 ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

spider_user() { grep -hE '^SPIDER_USER=' .env 2>/dev/null | tail -1 | cut -d= -f2- || true; }

announce() {
  local user
  user="$(spider_user)"
  echo
  echo "Register this public key on the cluster for ${user:-SPIDER_USER}:"
  echo
  cat "${KEY}.pub"
  echo
  echo "Until it is registered, the stack starts but cannot reach the cluster."
  echo "Verify once it is: make check"
}

if [[ "${SHOW}" -eq 1 ]]; then
  if [[ ! -s "${KEY}.pub" ]]; then
    echo "No key at ${KEY}.pub; generate one with: make new-key" >&2
    exit 1
  fi
  announce
  exit 0
fi

# Replacing the key cuts this deployment off from the cluster until somebody
# registers the replacement by hand. It does not revoke the old key: that stays
# authorised on the cluster until it is removed there.
# That is not something to do as a side effect of re-running a setup step.
if [[ -e "${KEY}" && "${FORCE}" -eq 0 ]]; then
  echo "${KEY} already exists." >&2
  echo >&2
  echo "Replacing it cuts this deployment off from the cluster until the new key" >&2
  echo "is registered there. The old key stays authorised until it is removed" >&2
  echo "on the cluster side." >&2
  echo >&2
  echo "  make new-key FORCE=1    replace it anyway" >&2
  echo "  make show-key           print the public half of the current key" >&2
  exit 1
fi

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

if [[ -e "${KEY}" ]]; then
  BACKUP="${KEY}.replaced-$(date -u +%Y%m%dT%H%M%SZ)"
  mv "${KEY}" "${BACKUP}"
  [[ -e "${KEY}.pub" ]] && mv "${KEY}.pub" "${BACKUP}.pub"
  chmod 600 "${BACKUP}"
  echo "Kept the previous key as ${BACKUP}"
fi

# The comment is a label, not an address. Spider's key registration form
# rejects anything shaped like an email, and "user@host.domain" is exactly that
# shape, so the host is joined with a dash instead of an @.
ssh-keygen -t ed25519 -N '' -C "slurm-access-$(hostname -f 2>/dev/null || hostname)" -f "${KEY}" >/dev/null
chmod 600 "${KEY}"
chmod 644 "${KEY}.pub"
echo "Generated ${KEY}"

# The cluster's host keys, so the first connection is not a trust-on-first-use
# prompt that a non-interactive deploy cannot answer.
touch "${SSH_DIR}/known_hosts"
ssh-keyscan -t rsa,ecdsa,ed25519 spider.surf.nl >> "${SSH_DIR}/known_hosts" 2>/dev/null
sort -u "${SSH_DIR}/known_hosts" -o "${SSH_DIR}/known_hosts"
chmod 644 "${SSH_DIR}/known_hosts"
echo "Collected cluster host keys into ${SSH_DIR}/known_hosts"

announce
