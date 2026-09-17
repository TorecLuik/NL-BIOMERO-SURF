#!/usr/bin/env bash
# Prepare a fresh SURF Research Cloud VM for NL-BIOMERO.
#
# Everything here is host setup that needs root: packages, Docker, the git
# submodule, the per-VM hostname values, and the nginx location block. It stops
# before deploying, because three things cannot be automated from inside the VM:
#
#   1. .env holds this VM's settings: copy .env.example and fill it in. The
#      credentials that unlock an attached volume come from the volume itself
#   2. ports 4063 and 4064 are opened in the SURF Research Cloud interface
#   3. the SSH public key must be authorised on Spider for SPIDER_USER
#
# Usage:
#   scripts/provision-vm.sh                 # prepare the host, then report
#   scripts/provision-vm.sh --skip-packages # host already has docker and git
#   scripts/provision-vm.sh --no-nginx      # leave host nginx alone
#
# After it finishes: fill in .env, `make new-key`, `make init`, `make deploy`.
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
  # Some Research Cloud images already ship Docker CE from download.docker.com.
  # Its containerd.io conflicts with the containerd that Ubuntu's docker.io
  # pulls in, and apt then refuses the whole transaction -- including the
  # unrelated packages below. Docker CE is newer and works with this stack, so
  # leave it in place and install only what is missing around it.
  PACKAGES=(git make curl)
  if dpkg -s docker-ce >/dev/null 2>&1; then
    ok "docker-ce already installed; leaving it alone"
  else
    PACKAGES+=(docker.io)
  fi
  if docker compose version >/dev/null 2>&1; then
    ok "compose plugin already installed"
  else
    PACKAGES+=(docker-compose-plugin)
  fi
  sudo apt-get update -qq
  sudo apt-get install -y -qq "${PACKAGES[@]}"
  sudo systemctl enable --now docker
  ok "installed: ${PACKAGES[*]}"
else
  warn "no apt-get; install docker, docker-compose-plugin, git and make by hand"
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
    warn "no /etc/nginx/.htpasswd; /logs answers 401 until it exists:"
    warn "  make logs-auth"
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
SPIDER_USER_VAL="$(grep -hE '^SPIDER_USER=' .env 2>/dev/null | tail -1 | cut -d= -f2- || true)"

if [[ -f .env ]]; then
  ok ".env present"
else
  warn ".env missing; copy .env.example to .env and fill it in"
  MISSING=1
fi

SLURM_KEY_NAME="$(grep -hE '^SLURM_ACCESS_KEY=' .env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
SLURM_KEY_NAME="${SLURM_KEY_NAME:-slurm_access_key}"
if [[ -s ".ssh/${SLURM_KEY_NAME}" ]]; then
  ok "cluster SSH key present"
  # .ssh/config is written for biomeroworker, which copies .ssh/ into its own
  # home, so its ~ paths do not resolve to this directory on the host. Point at
  # the files directly instead of using -F.
  if timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=15 \
      -o IdentitiesOnly=yes -i ".ssh/${SLURM_KEY_NAME}" \
      -o UserKnownHostsFile=.ssh/known_hosts -o StrictHostKeyChecking=yes \
      "${SPIDER_USER_VAL}@spider.surf.nl" 'true' 2>/dev/null; then
    ok "Spider accepts the key"
  else
    warn "the cluster has not accepted this key; register it for ${SPIDER_USER_VAL:-SPIDER_USER}:"
    warn "  make show-key"
    MISSING=1
  fi
else
  warn ".ssh/${SLURM_KEY_NAME} missing; generate one with: make new-key"
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
  echo "Then: cp .env.example .env and fill it in, make new-key, make init, make deploy"
  exit 1
fi

echo "Host prepared. Next: cp .env.example .env and fill it in, then make init"
