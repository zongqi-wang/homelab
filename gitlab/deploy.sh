#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: $ENV_FILE not found. Copy .env.example to .env and fill in values."
  exit 1
fi

# shellcheck source=.env
source "$ENV_FILE"
: "${LAN_HOST:?Set LAN_HOST in .env}"
AUTOKUMA_DEFAULT_NOTIFICATION_NAME_LIST="${AUTOKUMA_DEFAULT_NOTIFICATION_NAME_LIST:-[\"Homelab Alerts\"]}"

mkdir -p /mnt/user/appdata/gitea
mkdir -p /mnt/user/appdata/act-runner

KUMA_NOTIF=$(echo "$AUTOKUMA_DEFAULT_NOTIFICATION_NAME_LIST" | sed "s/'/\\\\'/g")
cat > /mnt/user/appdata/gitlab/docker-compose.yml <<YML
services:
  gitea:
    image: gitea/gitea:latest
    container_name: gitea
    labels:
      kuma.gitea.docker.name: gitea
    environment:
      - USER_UID=99
      - USER_GID=100
      - GITEA__server__DOMAIN=${LAN_HOST}
      - GITEA__server__SSH_PORT=2424
      - GITEA__server__HTTP_PORT=8929
      - GITEA__server__ROOT_URL=http://${LAN_HOST}:8929/
      - GITEA__actions__ENABLED=true
    ports:
      - "8929:8929"
      - "2424:22"
    volumes:
      - /mnt/user/appdata/gitea:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    restart: unless-stopped

  act-runner:
    image: gitea/act_runner:latest
    container_name: act-runner
    labels:
      kuma.act-runner.docker.name: act-runner
    depends_on:
      - gitea
    environment:
      - GITEA_INSTANCE_URL=http://gitea:8929
      - GITEA_RUNNER_REGISTRATION_TOKEN=
    volumes:
      - /mnt/user/appdata/act-runner:/data
      - /var/run/docker.sock:/var/run/docker.sock
    restart: unless-stopped
YML

cd /mnt/user/appdata/gitlab
docker compose pull
docker compose up -d

if docker ps --format '{{.Names}}' | grep -qx 'autokuma'; then
  echo "Triggering AutoKuma resync..."
  docker restart autokuma >/dev/null 2>&1 || true
fi

# Wait for Gitea to be ready
echo "Waiting for Gitea to initialize..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:8929/api/v1/version >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# Create admin user (silently fails if already exists)
if [ -n "${GITEA_ADMIN_USER}" ] && [ -n "${GITEA_ADMIN_PASSWORD}" ]; then
  docker exec gitea gitea admin user create \
    --admin \
    --username "${GITEA_ADMIN_USER}" \
    --password "${GITEA_ADMIN_PASSWORD}" \
    --email "${GITEA_ADMIN_EMAIL:-admin@localhost}" \
    2>/dev/null || true
fi

# Register the runner
echo "Registering act_runner..."
RUNNER_TOKEN=$(curl -sf -X POST \
  -H "Content-Type: application/json" \
  -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
  "http://localhost:8929/api/v1/user/actions/runners/registration-token" 2>/dev/null | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [ -n "$RUNNER_TOKEN" ]; then
  docker exec act-runner act_runner register \
    --instance http://gitea:8929 \
    --token "$RUNNER_TOKEN" \
    --name homelab-runner \
    --no-interactive 2>/dev/null || true
  echo "Runner registered."
else
  echo "Note: Could not get runner token. Register manually via Gitea UI > Site Administration > Runners."
fi

echo "Gitea deployment complete!"
