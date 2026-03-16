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

echo "Starting Phase 1: Bootstrap Directories..."
# Create data and appdata directories
mkdir -p /mnt/user/data/downloads/torrents/{incomplete,complete}
mkdir -p /mnt/user/data/downloads/usenet/{incomplete,complete}
mkdir -p /mnt/user/data/media/{movies,tv,anime,music}
mkdir -p /mnt/user/data/transcodes
mkdir -p /mnt/user/data/photos/library
mkdir -p /mnt/user/data/nextcloud
mkdir -p /mnt/user/data/documents/{consume,export}

# Appdata folders
mkdir -p /mnt/user/appdata/{gluetun,qbittorrent,sabnzbd,prowlarr,sonarr,radarr,lidarr,bazarr,recyclarr,unpackerr,jellyfin,jellyseerr,node-exporter,homepage,cloudflared,uptime-kuma,autokuma,vaultwarden,alertmanager}
mkdir -p /mnt/user/appdata/tdarr/{server,configs,logs,transcode_cache}
mkdir -p /mnt/user/appdata/immich/{postgres,model-cache}
mkdir -p /mnt/user/appdata/grafana/{provisioning/datasources,provisioning/dashboards,dashboards}
mkdir -p /mnt/user/appdata/prometheus/{data,rules}
mkdir -p /mnt/user/appdata/{nextcloud,nextcloud-db,paperless,paperless-db,paperless-redis,gotenberg,tika}
mkdir -p /mnt/user/appdata/{gitea,act-runner}

# Set permissions
chown -R 99:100 /mnt/user/data/downloads /mnt/user/data/media /mnt/user/data/photos
chmod -R ug+rwX,o+rx /mnt/user/data/downloads /mnt/user/data/media

# 99:100 for linuxserver containers
for d in gluetun qbittorrent sabnzbd prowlarr sonarr radarr lidarr bazarr recyclarr unpackerr jellyfin uptime-kuma autokuma vaultwarden cloudflared homepage tdarr; do
  chown -R 99:100 "/mnt/user/appdata/$d"
done

# Specific container permissions
chown -R 999:999 /mnt/user/appdata/immich/postgres /mnt/user/appdata/nextcloud-db
chown -R 472:472 /mnt/user/appdata/grafana
chown -R 65534:65534 /mnt/user/appdata/prometheus
chown -R 1000:1000 /mnt/user/appdata/jellyseerr /mnt/user/appdata/paperless /mnt/user/data/documents
chown -R 33:33 /mnt/user/appdata/nextcloud /mnt/user/data/nextcloud

echo "Phase 1 complete."

echo "Starting Phase 2: Copying Config Files..."
cp -r "${SCRIPT_DIR}/core/homepage" /mnt/user/appdata/
cp -r "${SCRIPT_DIR}/observability/prometheus" /mnt/user/appdata/
cp -r "${SCRIPT_DIR}/observability/alertmanager" /mnt/user/appdata/
cp -r "${SCRIPT_DIR}/observability/grafana" /mnt/user/appdata/
echo "Phase 2 complete."

echo "Starting Phase 3: Creating Network..."
docker network create homelab_net 2>/dev/null || true
echo "Phase 3 complete."

echo "Starting Phase 4: Deploying Stacks..."
STACKS="security core media automation download cloud observability"

for stack in $STACKS; do
    echo "Deploying $stack..."
    cd "${SCRIPT_DIR}/$stack"
    docker compose --env-file "${ENV_FILE}" pull
    docker compose --env-file "${ENV_FILE}" up -d
done

echo "Running post-deployment scripts..."

# Wait for Nextcloud to initialize
echo "Fixing Nextcloud permissions..."
sleep 15
docker exec nextcloud chown -R www-data:www-data /var/www/html/.htaccess /var/www/html/config /var/www/html/custom_apps /var/www/html/themes 2>/dev/null || true
docker exec nextcloud chmod 644 /var/www/html/.htaccess 2>/dev/null || true

# Check qBittorrent networking
QBIT_API_CODE="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/api/v2/app/webapiVersion || true)"
if [ "$QBIT_API_CODE" != "200" ]; then
  echo "qBittorrent API not reachable on port 8080 (HTTP ${QBIT_API_CODE:-ERR}), recreating qbittorrent..."
  cd "${SCRIPT_DIR}/download"
  docker compose --env-file "${ENV_FILE}" up -d --force-recreate qbittorrent
fi

echo "Phase 5: Reconciling AutoKuma monitors..."
reconcile_autokuma_monitors() {
  local expected_map=/tmp/autokuma-expected-map.txt
  local expected_names=/tmp/autokuma-expected-names.txt
  local monitor_names=/tmp/autokuma-monitor-names.txt
  local missing_names=/tmp/autokuma-missing-names.txt
  local monitor_name
  local container
  local i

  if ! docker ps --format '{{.Names}}' | grep -qx 'autokuma'; then
    echo "AutoKuma container not running; skipping monitor reconciliation."
    return 0
  fi

  docker restart autokuma >/dev/null 2>&1 || true

  for i in $(seq 1 30); do
    if docker exec autokuma kuma monitor list >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  if ! docker exec autokuma kuma monitor list >/dev/null 2>&1; then
    echo "Warning: AutoKuma API not ready; skipping monitor reconciliation."
    return 0
  fi

  : > "$expected_map"
  for container in $(docker ps --format '{{.Names}}'); do
    monitor_name="$(docker inspect "$container" --format '{{range $k, $v := .Config.Labels}}{{printf "%s=%s\n" $k $v}}{{end}}' 2>/dev/null | awk -F= '/^kuma\..*\.docker\.name=/{print $2; exit}')"
    if [ -n "$monitor_name" ]; then
      printf '%s|%s\n' "$monitor_name" "$container" >> "$expected_map"
    fi
  done

  if [ ! -s "$expected_map" ]; then
    echo "No AutoKuma-labeled containers found; skipping monitor reconciliation."
    return 0
  fi

  cut -d'|' -f1 "$expected_map" | sort -u > "$expected_names"
  docker exec autokuma kuma monitor list 2>/dev/null \
    | tr -d '\n' \
    | grep -o '"name":"[^"]*"' \
    | sed 's/"name":"//;s/"$//' \
    | sort -u > "$monitor_names" || true
  [ -f "$monitor_names" ] || : > "$monitor_names"

  comm -23 "$expected_names" "$monitor_names" > "$missing_names" || true

  if [ ! -s "$missing_names" ]; then
    echo "AutoKuma monitors are in sync."
    return 0
  fi

  echo "Missing AutoKuma monitors detected. Restarting related containers to trigger discovery..."
  while IFS= read -r monitor_name; do
    [ -n "$monitor_name" ] || continue
    container="$(awk -F'|' -v n="$monitor_name" '$1==n {print $2; exit}' "$expected_map")"
    if [ -n "$container" ]; then
      echo "  - $monitor_name ($container)"
      docker restart "$container" >/dev/null 2>&1 || true
    fi
  done < "$missing_names"
}

reconcile_autokuma_monitors

echo "Phase 6: Bootstrapping Uptime Kuma status page..."
setup_uptime_kuma_status_page() {
  local slug="${UPTIME_KUMA_STATUS_PAGE_SLUG:-default}"
  local title="${UPTIME_KUMA_STATUS_PAGE_TITLE:-Homelab Status}"
  local description="${UPTIME_KUMA_STATUS_PAGE_DESCRIPTION:-Automated status page}"
  local published="${UPTIME_KUMA_STATUS_PAGE_PUBLISHED:-true}"
  local domain_list_json="${UPTIME_KUMA_STATUS_PAGE_DOMAIN_LIST_JSON:-[]}"
  local public_group_name="${UPTIME_KUMA_STATUS_PAGE_GROUP_NAME:-Services}"
  local ready=0
  local i

  for i in $(seq 1 30); do
    if docker exec autokuma kuma status-page list >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 2
  done

  if [ "$ready" -ne 1 ]; then
    echo "Warning: Uptime Kuma API not ready; skipping status page bootstrap."
    return 0
  fi

  local public_group_list='[]'
  local has_jq=0
  if command -v jq >/dev/null 2>&1; then
    has_jq=1
    local monitors_json
    monitors_json="$(docker exec autokuma kuma monitor list 2>/dev/null || true)"
    if [ -n "$monitors_json" ] && printf '%s' "$monitors_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
      public_group_list="$(printf '%s' "$monitors_json" | jq -c --arg g "$public_group_name" '
        [
          {
            name: $g,
            weight: 1,
            monitorList: (
              [
                .[]
                | select(.id != null and .type != "group" and .name != null)
                | { id: .id, name: .name, weight: 1, type: .type }
              ]
            )
          }
        ]'
      )"
    fi
  else
    echo "Note: jq not found on host."
  fi

  if [ "$has_jq" -ne 1 ] && docker exec autokuma kuma status-page get "$slug" >/dev/null 2>&1; then
    echo "Preserving existing status page monitor groups (jq is required for auto-population)."
    return 0
  fi

  local slug_escaped title_escaped description_escaped
  slug_escaped=$(printf '%s' "$slug" | sed 's/\\/\\\\/g; s/"/\\"/g')
  title_escaped=$(printf '%s' "$title" | sed 's/\\/\\\\/g; s/"/\\"/g')
  description_escaped=$(printf '%s' "$description" | sed 's/\\/\\\\/g; s/"/\\"/g')

  cat > /tmp/uptime-kuma-status-page.json <<JSON
{
  "slug": "$slug_escaped",
  "title": "$title_escaped",
  "description": "$description_escaped",
  "published": $published,
  "showTags": true,
  "showPoweredBy": false,
  "publicGroupList": $public_group_list,
  "domainNameList": $domain_list_json
}
JSON

  if ! docker cp /tmp/uptime-kuma-status-page.json autokuma:/tmp/uptime-kuma-status-page.json >/dev/null 2>&1; then
    echo "Warning: Could not copy status page definition into autokuma container."
    return 0
  fi

  if docker exec autokuma kuma status-page get "$slug" >/dev/null 2>&1; then
    if docker exec autokuma kuma status-page edit /tmp/uptime-kuma-status-page.json >/dev/null 2>&1; then
      echo "Uptime Kuma status page '$slug' updated."
    else
      echo "Warning: Failed to update Uptime Kuma status page '$slug'."
    fi
  else
    if docker exec autokuma kuma status-page add /tmp/uptime-kuma-status-page.json >/dev/null 2>&1; then
      echo "Uptime Kuma status page '$slug' created."
    else
      echo "Warning: Failed to create Uptime Kuma status page '$slug'."
    fi
  fi
}

setup_uptime_kuma_status_page

echo "Stack deployed successfully!"
