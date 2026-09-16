#!/usr/bin/env bash
# Prepare a fresh SURF Research Cloud VM for NL-BIOMERO.
#
# Everything here is host setup that needs root: packages, Docker, the git
# submodule, the per-VM hostname values, and the nginx location block. It stops
# before deploying, because three things cannot be automated from inside the VM:
#
#   1. .env and .ssh/ hold the deployment secrets and exist only in your archive
#   2. ports 4063 and 4064 are opened in the SURF Research Cloud interface
#   3. the SSH public key must be authorised on Spider for SPIDER_USER
#
# Usage:
#   scripts/provision-vm.sh                 # prepare the host, then report
#   scripts/provision-vm.sh --skip-packages # host already has docker and git
#   scripts/provision-vm.sh --no-nginx      # leave host nginx alone
#
# After it finishes: restore the secrets, then run `make deploy`.
set -euo pipefail

PROJECT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT_DIR}"

SKIP_PACKAGES=0
DO_NGINX=1
for arg in "$@"; do
  case "${arg}" in
    --skip-packages) SKIP_PACKAGES=1 ;;
    --no-nginx)      DO_NGINX=0 ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

step() { printf '\n== %s ==\n' "$1"; }
ok()   { printf '  [ ok ] %s\n' "$1"; }
warn() { printf '  [warn] %s\n' "$1"; }

PUBLIC_HOST="$(hostname -f 2>/dev/null || hostname)"

# ------------------------------------------------------------------ packages --
step "Host packages"
if [[ "${SKIP_PACKAGES}" -eq 1 ]]; then
  ok "skipped"
elif command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker.io docker-compose-plugin git make apache2-utils curl
  sudo systemctl enable --now docker
  ok "docker, compose, git, make, htpasswd installed"
else
  warn "no apt-get; install docker, docker-compose-plugin, git, make and htpasswd by hand"
fi

# Docker needs sudo on this deployment, which every make target already assumes,
# so group membership is a convenience rather than a requirement.
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  sudo usermod -aG docker "$USER" 2>/dev/null \
    && warn "added $USER to the docker group; log out and back in for it to apply" \
    || true
fi

# ----------------------------------------------------------------- submodule --
step "Importer submodule"
if [[ -f biomero-importer/Dockerfile ]]; then
  ok "already present at $(cd biomero-importer && git describe --tags 2>/dev/null || echo unknown)"
else
  git submodule update --init --recursive
  if [[ -f biomero-importer/Dockerfile ]]; then
    ok "fetched $(cd biomero-importer && git describe --tags 2>/dev/null || echo unknown)"
  else
    warn "submodule is still empty; the importer image cannot build"
  fi
fi

# ------------------------------------------------------------------ hostname --
step "Per-VM hostname"
if [[ -f .env || -f .env.shared ]]; then
  make --no-print-directory set-host "HOST=${PUBLIC_HOST}" >/dev/null
  ok "set to ${PUBLIC_HOST}"
else
  warn ".env and .env.shared are both missing; run set-host after restoring them"
fi

# --------------------------------------------------------------------- nginx --
step "Host nginx"
NGINX_DIR=/etc/nginx/app-location-conf.d
NGINX_LOCATION="${NGINX_DIR}/omero-web.conf"
if [[ "${DO_NGINX}" -eq 0 ]]; then
  ok "skipped"
elif ! command -v nginx >/dev/null 2>&1; then
  warn "nginx is not installed; SURF Research Cloud normally provides it"
else
  sudo mkdir -p "${NGINX_DIR}"
  sudo cp nginx/omero-web.conf "${NGINX_LOCATION}"
  if [[ -f /etc/nginx/.htpasswd ]]; then
    ok "htpasswd already present"
  else
    # /logs is behind basic auth, and nginx fails the location without this file.
    warn "no /etc/nginx/.htpasswd; create one before using /logs:"
    warn "  sudo htpasswd -c /etc/nginx/.htpasswd <admin-user>"
  fi
  if sudo nginx -t >/dev/null 2>&1; then
    sudo systemctl reload nginx
    ok "location block installed and nginx reloaded"
  else
    warn "nginx -t failed; not reloading. Check: sudo nginx -t"
  fi
fi

# ------------------------------------------------------------------- report --
step "What this script cannot do"

MISSING=0

if [[ -f .env ]]; then
  ok ".env present"
else
  warn ".env missing: restore it from your archive, it is the only copy"
  MISSING=1
fi

if [[ -s .ssh/id_rsa ]]; then
  ok "Spider SSH key present"
  if timeout 25 ssh -F .ssh/config -o BatchMode=yes -o ConnectTimeout=15 spider 'true' 2>/dev/null; then
    ok "Spider accepts the key"
  else
    warn "Spider did not accept the key; authorise the public key for SPIDER_USER"
    MISSING=1
  fi
else
  warn ".ssh/id_rsa missing: restore it from your archive"
  MISSING=1
fi

# 4063/4064 are opened in the SURF Research Cloud interface, not on the host,
# so this can only report what is reachable.
for port in 4063 4064; do
  if timeout 6 bash -c "echo > /dev/tcp/${PUBLIC_HOST}/${port}" 2>/dev/null; then
    ok "port ${port} reachable"
  else
    warn "port ${port} not reachable: open it in the SURF Research Cloud interface for OMERO.insight"
    MISSING=1
  fi
done

printf '\n'
if [[ "${MISSING}" -eq 1 ]]; then
  echo "Host prepared, but the items above need attention first."
  echo "Then run: make deploy"
  exit 1
fi

echo "Host prepared. Next: make deploy"
