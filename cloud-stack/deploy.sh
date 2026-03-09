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

echo "Starting Bootstrap for Nextcloud and Paperless..."
mkdir -p /mnt/user/appdata/{nextcloud,nextcloud-db,paperless,paperless-db,paperless-redis,gotenberg,tika}
mkdir -p /mnt/user/data/nextcloud
mkdir -p /mnt/user/data/documents/{consume,export}

chown -R 33:33 /mnt/user/appdata/nextcloud
chown -R 33:33 /mnt/user/data/nextcloud
chown -R 999:999 /mnt/user/appdata/nextcloud-db
chown -R 1000:1000 /mnt/user/appdata/paperless
chown -R 1000:1000 /mnt/user/data/documents

echo "Creating Compose Stack..."
mkdir -p /mnt/user/appdata/cloud-stack
cat > /mnt/user/appdata/cloud-stack/docker-compose.yml <<EOF
services:
  nextcloud-db:
    image: mariadb:10.6
    container_name: nextcloud-db
    labels:
      kuma.nextcloud-db.docker.name: nextcloud-db
      kuma.nextcloud-db.docker.notification_name_list: "${AUTOKUMA_DEFAULT_NOTIFICATION_NAME_LIST}"
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
      - MYSQL_DATABASE=${MYSQL_DATABASE}
      - MYSQL_USER=${MYSQL_USER}
    volumes:
      - /mnt/user/appdata/nextcloud-db:/var/lib/mysql
    restart: unless-stopped

  nextcloud:
    image: nextcloud:apache
    container_name: nextcloud
    labels:
      kuma.nextcloud.docker.name: nextcloud
      kuma.nextcloud.docker.notification_name_list: "${AUTOKUMA_DEFAULT_NOTIFICATION_NAME_LIST}"
    ports:
      - "8086:80"
    environment:
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
      - MYSQL_DATABASE=${MYSQL_DATABASE}
      - MYSQL_USER=${MYSQL_USER}
      - MYSQL_HOST=nextcloud-db
    volumes:
      - /mnt/user/appdata/nextcloud:/var/www/html
      - /mnt/user/data/nextcloud:/var/www/html/data
      - /mnt/user/data/documents:/mnt/paperless_docs
    depends_on:
      - nextcloud-db
    restart: unless-stopped

  paperless-redis:
    image: redis:7
    container_name: paperless-redis
    labels:
      kuma.paperless-redis.docker.name: paperless-redis
      kuma.paperless-redis.docker.notification_name_list: "${AUTOKUMA_DEFAULT_NOTIFICATION_NAME_LIST}"
    volumes:
      - /mnt/user/appdata/paperless-redis:/data
    restart: unless-stopped

  paperless-db:
    image: postgres:15
    container_name: paperless-db
    labels:
      kuma.paperless-db.docker.name: paperless-db
      kuma.paperless-db.docker.notification_name_list: "${AUTOKUMA_DEFAULT_NOTIFICATION_NAME_LIST}"
    environment:
      - POSTGRES_DB=paperless
      - POSTGRES_USER=paperless
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - /mnt/user/appdata/paperless-db:/var/lib/postgresql/data
    restart: unless-stopped

  gotenberg:
    image: gotenberg/gotenberg:8
    container_name: gotenberg
    labels:
      kuma.gotenberg.docker.name: gotenberg
      kuma.gotenberg.docker.notification_name_list: "${AUTOKUMA_DEFAULT_NOTIFICATION_NAME_LIST}"
    command:
      - "gotenberg"
      - "--chromium-disable-javascript=true"
      - "--chromium-allow-list=file:///tmp/.*"
    restart: unless-stopped

  tika:
    image: apache/tika:latest
    container_name: tika
    labels:
      kuma.tika.docker.name: tika
      kuma.tika.docker.notification_name_list: "${AUTOKUMA_DEFAULT_NOTIFICATION_NAME_LIST}"
    restart: unless-stopped

  paperless:
    image: ghcr.io/paperless-ngx/paperless-ngx:latest
    container_name: paperless
    labels:
      kuma.paperless.docker.name: paperless
      kuma.paperless.docker.notification_name_list: "${AUTOKUMA_DEFAULT_NOTIFICATION_NAME_LIST}"
    ports:
      - "8000:8000"
    depends_on:
      - paperless-db
      - paperless-redis
      - gotenberg
      - tika
    environment:
      - USERMAP_UID=1000
      - USERMAP_GID=1000
      - PAPERLESS_REDIS=redis://paperless-redis:6379
      - PAPERLESS_DBHOST=paperless-db
      - PAPERLESS_DBNAME=paperless
      - PAPERLESS_DBUSER=paperless
      - PAPERLESS_DBPASS=${POSTGRES_PASSWORD}
      - PAPERLESS_TIKA_ENABLED=1
      - PAPERLESS_TIKA_GOTENBERG_ENDPOINT=http://gotenberg:3000
      - PAPERLESS_TIKA_ENDPOINT=http://tika:9998
      - PAPERLESS_URL=http://${LAN_HOST}:8000
      - PAPERLESS_ADMIN_USER=${PAPERLESS_ADMIN_USER}
      - PAPERLESS_ADMIN_PASSWORD=${PAPERLESS_ADMIN_PASSWORD}
      - PAPERLESS_SECRET_KEY=${PAPERLESS_SECRET_KEY}
      - PAPERLESS_CONSUMER_RECURSIVE=true
      - PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS=true
    volumes:
      - /mnt/user/data/documents:/usr/src/paperless/data
      - /mnt/user/data/documents/consume:/usr/src/paperless/consume
      - /mnt/user/data/nextcloud/admin/files/Documents:/usr/src/paperless/consume_nextcloud
      - /mnt/user/data/documents/export:/usr/src/paperless/export
      - /mnt/user/appdata/paperless:/usr/src/paperless/media
    restart: unless-stopped
EOF

echo "Deploying Stack..."
cd /mnt/user/appdata/cloud-stack
docker compose pull
docker compose up -d

if docker ps --format '{{.Names}}' | grep -qx 'autokuma'; then
  echo "Triggering AutoKuma resync..."
  docker restart autokuma >/dev/null 2>&1 || true
fi

echo "Waiting for Nextcloud to initialize..."
sleep 15
docker exec nextcloud chown -R www-data:www-data /var/www/html/.htaccess /var/www/html/config /var/www/html/custom_apps /var/www/html/themes 2>/dev/null || true
docker exec nextcloud chmod 644 /var/www/html/.htaccess 2>/dev/null || true
echo "Nextcloud permissions fixed."

echo "Deployment Complete!"
