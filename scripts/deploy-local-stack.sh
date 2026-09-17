#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGIN_USER="${SUDO_USER:-${USER}}"
LOGIN_HOME="$(getent passwd "${LOGIN_USER}" | cut -d: -f6)"
ENV_PATH="${PROJECT_ROOT_DIR}/.env"
START_LOG_STACK="${START_LOG_STACK:-1}"
SSH_DIR="${PROJECT_ROOT_DIR}/.ssh"
# L-Drive and the secrets live on the attached storage volume, not in the repo.
# Resolve it the way docker-compose.yml does. See
# deployment_docs/storage-architecture.md.
OMERO_DATA_PATH_VAL="$(grep -hE '^OMERO_DATA_PATH=' "${PROJECT_ROOT_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2-)"
LDRIVE_DIR="${OMERO_DATA_PATH_VAL}/L-Drive"
SLURM_CONFIG_PATH="${PROJECT_ROOT_DIR}/web/slurm-config.ini"
SLURM_TEMPLATE_PATH="${PROJECT_ROOT_DIR}/web/slurm-config-template.ini"
BIOMERO_CONFIG_PATH="${PROJECT_ROOT_DIR}/web/biomero-config.json"
GROUP_MAPPINGS_CONFIG_PATH="${PROJECT_ROOT_DIR}/web/group-mappings.json"
MOUNT_SSH_SCRIPT_PATH="${PROJECT_ROOT_DIR}/biomeroworker/10-mount-ssh.sh"
IMPORTER_DIR="${PROJECT_ROOT_DIR}/biomero-importer"
IMPORTER_DOCKERFILE_PATH="${IMPORTER_DIR}/Dockerfile"

LOG_DIRS=(
  "${PROJECT_ROOT_DIR}/logs/omeroserver"
  "${PROJECT_ROOT_DIR}/logs/omeroworker-1"
  "${PROJECT_ROOT_DIR}/logs/biomeroworker"
  "${PROJECT_ROOT_DIR}/logs/omeroweb"
  "${PROJECT_ROOT_DIR}/logs/biomero-importer"
)


# This helper assumes NL-BIOMERO itself is already cloned, since the script
# lives inside that checkout. If you are starting from scratch, clone with:
# git clone https://github.com/Cellular-Imaging-Amsterdam-UMC/NL-BIOMERO.git /opt/omero/NL-BIOMERO
#
# To open the UIs from your laptop, connect with:
# ssh -L 4080:localhost:4080 -L 3000:localhost:3000 -L 5601:localhost:5601 <user>@<server>

# Run all file operations relative to the repository root.
cd "${PROJECT_ROOT_DIR}"

echo "Reminder: access the web UIs via SSH port forwarding:"
echo "  ssh -L 4080:localhost:4080 -L 3000:localhost:3000 -L 5601:localhost:5601 <user>@<server>"

# .env holds the deployment secrets and is not in git. It normally lives in
# config/ on the attached storage volume, with .env here as a symlink to it --
# see deployment_docs/storage-architecture.md.
#
# If the volume has one, link it rather than seeding a local copy: a real file
# here would shadow the volume's copy of slurm-config.ini.
if [[ ! -e "${ENV_PATH}" && -f "${OMERO_DATA_PATH_VAL}/config/.env" ]]; then
  ln -s "${OMERO_DATA_PATH_VAL}/config/.env" "${ENV_PATH}"
  echo "Linked ${ENV_PATH} -> ${OMERO_DATA_PATH_VAL}/config/.env"
fi

# Without .env there is nothing to deploy from. Seeding one from a template
# would produce a stack that starts with placeholder database passwords and
# fails later, so stop here instead.
if [[ ! -e "${ENV_PATH}" ]]; then
  echo "Missing ${ENV_PATH}." >&2
  echo "  cp .env.example .env    then fill in every value marked CHANGE ME" >&2
  exit 1
fi

if ! grep -q '^SPIDER_USER=' "${ENV_PATH}"; then
  printf '\nSPIDER_USER=\n' >> "${ENV_PATH}"
  echo "Added SPIDER_USER= to ${ENV_PATH}"
fi

if ! grep -q '^SPIDER_PROJECT=' "${ENV_PATH}"; then
  printf '\nSPIDER_PROJECT=\n' >> "${ENV_PATH}"
  echo "Added SPIDER_PROJECT= to ${ENV_PATH}"
fi

if [[ -f "${ENV_PATH}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_PATH}"
  set +a
fi

# Prompt once for the Spider username/project and persist them for later runs.
if [[ -z "${SPIDER_USER:-}" ]]; then
  read -r -p "Enter your Spider username: " SPIDER_USER
  if [[ -z "${SPIDER_USER}" ]]; then
    echo "SPIDER_USER is required."
    exit 1
  fi

  if grep -q '^SPIDER_USER=' "${ENV_PATH}"; then
    sed -i "s/^SPIDER_USER=.*/SPIDER_USER=${SPIDER_USER}/" "${ENV_PATH}"
  else
    printf '\nSPIDER_USER=%s\n' "${SPIDER_USER}" >> "${ENV_PATH}"
  fi
fi

if [[ -z "${SPIDER_PROJECT:-}" ]]; then
  read -r -p "Enter your Spider project name: " SPIDER_PROJECT
  if [[ -z "${SPIDER_PROJECT}" ]]; then
    echo "SPIDER_PROJECT is required."
    exit 1
  fi

  if grep -q '^SPIDER_PROJECT=' "${ENV_PATH}"; then
    sed -i "s/^SPIDER_PROJECT=.*/SPIDER_PROJECT=${SPIDER_PROJECT}/" "${ENV_PATH}"
  else
    printf '\nSPIDER_PROJECT=%s\n' "${SPIDER_PROJECT}" >> "${ENV_PATH}"
  fi
fi

# The importer image builds from the biomero-importer/ submodule, so fetch it
# through git rather than cloning a URL by hand. An earlier version cloned a
# different fork here, which silently produced an importer built from the wrong
# source whenever the submodule was missing.
if [[ ! -f "${IMPORTER_DOCKERFILE_PATH}" ]]; then
  git -C "${PROJECT_ROOT_DIR}" submodule update --init --recursive
fi

if [[ ! -f "${IMPORTER_DOCKERFILE_PATH}" ]]; then
  echo "biomero-importer/ is still empty after submodule update." >&2
  echo "Fetch it manually, then re-run: git submodule update --init --recursive" >&2
  exit 1
fi

# Create the bind-mounted host paths the stack expects.
mkdir -p "${SSH_DIR}" "${LDRIVE_DIR}" "${LOG_DIRS[@]}"

# .ssh/ holds cluster access material and nothing else. The login user's ~/.ssh is left
# alone: the key that reaches this VM's git remote is a separate, disposable
# per-VM credential, while this key represents an authorisation granted on the
# cluster and travels between people and machines. Conflating them means a VM
# rebuild silently becomes a change to who can reach Spider.
SLURM_ACCESS_KEY_NAME="$(grep -hE '^SLURM_ACCESS_KEY=' "${ENV_PATH}" 2>/dev/null | tail -1 | cut -d= -f2-)"
SLURM_ACCESS_KEY_NAME="${SLURM_ACCESS_KEY_NAME:-slurm_access_key}"
if [[ ! -s "${SSH_DIR}/${SLURM_ACCESS_KEY_NAME}" ]]; then
  echo "Missing ${SSH_DIR}/${SLURM_ACCESS_KEY_NAME} -- the cluster SSH key." >&2
  echo "  make new-key    generate one, then register the public half" >&2
  exit 1
fi

touch "${SSH_DIR}/known_hosts"
ssh-keyscan -t rsa,ecdsa,ed25519 spider.surf.nl >> "${SSH_DIR}/known_hosts" 2>/dev/null
sort -u "${SSH_DIR}/known_hosts" -o "${SSH_DIR}/known_hosts"

# One config, written for biomeroworker, which copies this directory to its own
# ~/.ssh. IdentitiesOnly stops ssh offering any other key it finds before this
# one. Host-side checks pass -i explicitly rather than using this file, because
# ~ resolves to a different home on the host than in the container.
cat > "${SSH_DIR}/config" <<EOF
Host localslurm
    HostName 172.17.0.1
    User slurm
    Port 2222
    IdentityFile ~/.ssh/${SLURM_ACCESS_KEY_NAME}
    IdentitiesOnly yes
    UserKnownHostsFile ~/.ssh/known_hosts
    StrictHostKeyChecking no

Host spider
    HostName spider.surf.nl
    User ${SPIDER_USER}
    IdentityFile ~/.ssh/${SLURM_ACCESS_KEY_NAME}
    IdentitiesOnly yes
    UserKnownHostsFile ~/.ssh/known_hosts
    StrictHostKeyChecking yes
EOF

# Bootstrap a template from the current runtime config if the template is missing.
if [[ ! -f "${SLURM_TEMPLATE_PATH}" && -f "${SLURM_CONFIG_PATH}" ]]; then
  cp "${SLURM_CONFIG_PATH}" "${SLURM_TEMPLATE_PATH}"
  sed -i \
    -e "s#${SPIDER_USER}#\${SPIDER_USER}#g" \
    -e "s#${SPIDER_PROJECT}#\${SPIDER_PROJECT}#g" \
    "${SLURM_TEMPLATE_PATH}"
  echo "Generated ${SLURM_TEMPLATE_PATH} from ${SLURM_CONFIG_PATH}"
fi

# Render the runtime Slurm config from the parameterized template.
if [[ -f "${SLURM_TEMPLATE_PATH}" ]]; then
  "${PROJECT_ROOT_DIR}/scripts/render-slurm-config.sh"
fi

# Keep the worker startup script on the fixed SSH-copy implementation so
# restarts do not leave stale nested .ssh directories behind.
cat > "${MOUNT_SSH_SCRIPT_PATH}" <<'EOF'
#!/usr/bin/env bash
set -e

# Using `-v $HOME/.ssh:/opt/omero/server/.ssh:ro` produce permissions error while in the container
# when working from Linux and maybe from Windows.
# To prevent that we offer the strategy to mount the `.ssh` folder with
# `-v $HOME/.ssh:/tmp/.ssh:ro` thus this entrypoint will automatically handle problem.

if [[ -d /tmp/.ssh ]]; then
  # Replace the target directory contents on every startup to avoid nesting
  # /opt/omero/server/.ssh/.ssh on container restarts.
  rm -rf /opt/omero/server/.ssh
  mkdir -p /opt/omero/server/.ssh
  # TODO: error on windows ? this didn't copy 'config'
  cp -R /tmp/.ssh/. /opt/omero/server/.ssh/
  chmod 700 /opt/omero/server/.ssh
  chmod 600 /opt/omero/server/.ssh/*
  chmod 644 /opt/omero/server/.ssh/*.pub
  chmod 644 /opt/omero/server/.ssh/known_hosts
fi

exec "$@"
EOF
chmod 755 "${MOUNT_SSH_SCRIPT_PATH}"

sudo chmod -R 777 "${LDRIVE_DIR}" "${PROJECT_ROOT_DIR}/logs"
# OMERO.biomero writes these bind-mounted files from inside the web container.
# Keep them host-writable for uid 999 (omero-web), even after git checkout,
# template rendering, or rebuilds recreate them with normal 0644 permissions.
sudo chmod 666 "${SLURM_CONFIG_PATH}" "${BIOMERO_CONFIG_PATH}" "${GROUP_MAPPINGS_CONFIG_PATH}"

# biomeroworker mounts this directory read-only at /tmp/.ssh and copies it to
# /opt/omero/server/.ssh, where 10-mount-ssh.sh re-tightens its own copy to
# 0600. It runs as omero-server, uid 1000 gid 994, matching neither the owner
# nor the group of these files, so it would read them as "other" and the copy
# would fail with "cp: cannot stat '/tmp/.ssh/.': Permission denied".
#
# Granting the group instead of "other" is what keeps the key off-limits to
# other accounts on this VM: the group is the container's gid, so the worker
# reads the key and nobody else does. WORKER_GID must track the uid/gid the
# biomeroworker image runs as.
WORKER_GID=994
sudo chgrp -R "${WORKER_GID}" "${SSH_DIR}"
chmod 750 "${SSH_DIR}"
chmod 640 "${SSH_DIR}/${SLURM_ACCESS_KEY_NAME}"
chmod 644 "${SSH_DIR}/${SLURM_ACCESS_KEY_NAME}.pub" "${SSH_DIR}/known_hosts" "${SSH_DIR}/config"

# The importer container runs as uid/gid 1000 and needs write access to its log mount.
sudo chown -R 1000:1000 "${PROJECT_ROOT_DIR}/logs/biomero-importer"
sudo chmod -R 775 "${PROJECT_ROOT_DIR}/logs/biomero-importer"

# Bring up or refresh the full local stack. We keep --build here because
# biomeroworker startup behavior lives in the image via 10-mount-ssh.sh.
sudo docker compose up -d --build

# Metabase keeps its application database in Postgres on database-biomero, but
# Postgres only creates POSTGRES_DB at first init, so the metabase database does
# not exist on a fresh volume and Metabase would fail to start. Create it if
# missing; this is a no-op once it exists.
MB_DB_NAME="${MB_DB_NAME:-metabase}"
MB_PG_USER="${BIOMERO_POSTGRES_USER:-biomero}"
for _ in $(seq 1 30); do
  if sudo docker compose exec -T database-biomero \
       pg_isready -U "${MB_PG_USER}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if sudo docker compose exec -T database-biomero \
     psql -U "${MB_PG_USER}" -d postgres -tAc \
     "SELECT 1 FROM pg_database WHERE datname='${MB_DB_NAME}'" 2>/dev/null \
     | grep -q 1; then
  echo "Metabase application database '${MB_DB_NAME}' present."
else
  echo "Creating Metabase application database '${MB_DB_NAME}'..."
  sudo docker compose exec -T database-biomero \
    psql -U "${MB_PG_USER}" -d postgres \
    -c "CREATE DATABASE ${MB_DB_NAME} OWNER ${MB_PG_USER};"
  sudo docker compose restart metabase
fi
if [[ "${START_LOG_STACK}" != "0" && -f "${PROJECT_ROOT_DIR}/opensearch-compose.yml" ]]; then
  sudo docker compose -f opensearch-compose.yml up -d
fi
sudo docker compose ps
if [[ "${START_LOG_STACK}" != "0" && -f "${PROJECT_ROOT_DIR}/opensearch-compose.yml" ]]; then
  sudo docker compose -f opensearch-compose.yml ps
fi

echo "Cluster SSH material: ${SSH_DIR}"
