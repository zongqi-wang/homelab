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
: "${PROMETHEUS_DISCORD_WEBHOOK:?Set PROMETHEUS_DISCORD_WEBHOOK in .env}"
LAN_SUBNET="${LAN_SUBNET:-192.168.1.0/24}"

AUTOKUMA_DEFAULT_NOTIFICATION_NAME_LIST="${AUTOKUMA_DEFAULT_NOTIFICATION_NAME_LIST:-[\"Homelab Alerts\"]}"
AUTOKUMA_ALERT_PROVIDER_ACTIVE="${AUTOKUMA_ALERT_PROVIDER_ACTIVE:-false}"
AUTOKUMA_ALERT_PROVIDER_CONFIG_JSON="${AUTOKUMA_ALERT_PROVIDER_CONFIG_JSON:-{\"type\":\"webhook\",\"webhookURL\":\"http://127.0.0.1:65535\"}}"
UPTIME_KUMA_STATUS_PAGE_SLUG="${UPTIME_KUMA_STATUS_PAGE_SLUG:-default}"
UPTIME_KUMA_STATUS_PAGE_TITLE="${UPTIME_KUMA_STATUS_PAGE_TITLE:-Homelab Status}"
UPTIME_KUMA_STATUS_PAGE_DESCRIPTION="${UPTIME_KUMA_STATUS_PAGE_DESCRIPTION:-Automated status page}"
UPTIME_KUMA_STATUS_PAGE_PUBLISHED="${UPTIME_KUMA_STATUS_PAGE_PUBLISHED:-true}"
UPTIME_KUMA_STATUS_PAGE_GROUP_NAME="${UPTIME_KUMA_STATUS_PAGE_GROUP_NAME:-Services}"
UPTIME_KUMA_STATUS_PAGE_DOMAIN_LIST_JSON="${UPTIME_KUMA_STATUS_PAGE_DOMAIN_LIST_JSON:-[]}"

echo "Starting Phase 1: Bootstrap Directories..."
mkdir -p /mnt/user/data/downloads/torrents/{incomplete,complete}
mkdir -p /mnt/user/data/downloads/usenet/{incomplete,complete}
mkdir -p /mnt/user/data/media/{movies,tv,anime,music}
mkdir -p /mnt/user/appdata/{gluetun,qbittorrent,sabnzbd,prowlarr,sonarr,radarr,lidarr,bazarr,recyclarr,unpackerr,jellyfin,jellyseerr,tautulli,arr-stack,node-exporter}
mkdir -p /mnt/user/appdata/homepage
mkdir -p /mnt/user/appdata/cloudflared
mkdir -p /mnt/user/appdata/uptime-kuma
mkdir -p /mnt/user/appdata/autokuma
mkdir -p /mnt/user/data/photos/library
mkdir -p /mnt/user/appdata/immich/{postgres,model-cache}
mkdir -p /mnt/user/appdata/grafana
mkdir -p /mnt/user/appdata/grafana/provisioning/datasources
mkdir -p /mnt/user/appdata/grafana/provisioning/dashboards
mkdir -p /mnt/user/appdata/grafana/dashboards
mkdir -p /mnt/user/appdata/prometheus/{data,rules}
mkdir -p /mnt/user/appdata/alertmanager

chown -R 99:100 /mnt/user/data/downloads /mnt/user/data/media
chmod -R ug+rwX,o+rx /mnt/user/data/downloads /mnt/user/data/media
for d in gluetun qbittorrent sabnzbd prowlarr sonarr radarr lidarr bazarr recyclarr unpackerr jellyfin tautulli arr-stack homepage cloudflared uptime-kuma autokuma; do
  chown -R 99:100 /mnt/user/appdata/$d
done
chown -R 999:999 /mnt/user/appdata/immich/postgres
chown -R 472:472 /mnt/user/appdata/grafana
chown -R 65534:65534 /mnt/user/appdata/prometheus
chown -R 1000:1000 /mnt/user/appdata/jellyseerr
echo "Phase 1 complete."

echo "Starting Phase 2: Write .env + config files..."
if [ "$(realpath "$ENV_FILE")" != "$(realpath /mnt/user/appdata/arr-stack/.env)" ]; then
  cp "$ENV_FILE" /mnt/user/appdata/arr-stack/.env
fi

cat > /mnt/user/appdata/prometheus/prometheus.yml <<'YAML'
global:
  scrape_interval: 15s
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']
rule_files:
  - /etc/prometheus/rules/*.yml
scrape_configs:
  - job_name: 'cadvisor'
    static_configs:
      - targets: ['cadvisor:8080']
  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']
YAML

cat > /mnt/user/appdata/alertmanager/alertmanager.yml <<ALERTMGR
global:
  resolve_timeout: 5m

route:
  receiver: discord
  group_by: ['alertname']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: discord
    discord_configs:
      - webhook_url: '${PROMETHEUS_DISCORD_WEBHOOK}'
        title: '{{ .GroupLabels.alertname }}'
        message: '{{ range .Alerts }}{{ .Annotations.summary }}: {{ .Annotations.description }}{{ end }}'
ALERTMGR

cat > /mnt/user/appdata/prometheus/rules/container-health.yml <<'YAML'
groups:
  - name: container-health
    rules:
      - alert: HostCPUUsageHigh
        expr: (100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)) > 90
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Host CPU usage high"
          description: "Host {{ $labels.instance }} CPU usage has been above 90% for 10 minutes."

      - alert: HostMemoryUsageHigh
        expr: ((1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100) > 90
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Host memory usage high"
          description: "Host {{ $labels.instance }} memory usage has been above 90% for 10 minutes."

      - alert: ContainerDown
        expr: time() - container_last_seen{name!=""} > 120
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Container appears down"
          description: "Container {{ $labels.name }} has not been seen for over 2 minutes."

      - alert: ContainerOOM
        expr: increase(container_oom_events_total{name!=""}[10m]) > 0
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "Container OOM detected"
          description: "Container {{ $labels.name }} has experienced at least one OOM kill in the last 10 minutes."

      - alert: ContainerMemoryHigh
        expr: (container_memory_working_set_bytes{name!=""} / container_spec_memory_limit_bytes{name!=""}) > 0.90 and container_spec_memory_limit_bytes{name!=""} > 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Container memory usage high"
          description: "Container {{ $labels.name }} is above 90% of its memory limit."

      - alert: ContainerCPUHigh
        expr: (sum by (name) (rate(container_cpu_usage_seconds_total{name!=""}[5m])) / (sum by (name) (container_spec_cpu_quota{name!=""}) / sum by (name) (container_spec_cpu_period{name!=""}))) > 0.90 and sum by (name) (container_spec_cpu_quota{name!=""}) > 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Container CPU usage high"
          description: "Container {{ $labels.name }} CPU usage has been above 90% of its CPU limit for 10 minutes."
YAML

cat > /mnt/user/appdata/grafana/provisioning/datasources/prometheus.yml <<'YAML'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
    jsonData:
      httpMethod: POST
      timeInterval: 15s
YAML

cat > /mnt/user/appdata/grafana/provisioning/dashboards/default.yml <<'YAML'
apiVersion: 1
providers:
  - name: iac-dashboards
    orgId: 1
    folder: IaC
    type: file
    disableDeletion: false
    allowUiUpdates: true
    updateIntervalSeconds: 30
    options:
      path: /etc/grafana/dashboards
      foldersFromFilesStructure: false
YAML

cat > /mnt/user/appdata/grafana/dashboards/host-overview.json <<'JSON'
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 0,
  "id": null,
  "links": [],
  "liveNow": false,
  "panels": [
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": { "defaults": { "unit": "percent" }, "overrides": [] },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "id": 1,
      "options": { "legend": { "displayMode": "list", "placement": "bottom" } },
      "targets": [{ "expr": "100 - (avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)", "legendFormat": "{{instance}}", "refId": "A" }],
      "title": "Host CPU Usage (%)",
      "type": "timeseries"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": { "defaults": { "unit": "percent" }, "overrides": [] },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "id": 2,
      "targets": [{ "expr": "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100", "legendFormat": "{{instance}}", "refId": "A" }],
      "title": "Host Memory Used (%)",
      "type": "timeseries"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": { "defaults": { "unit": "Bps" }, "overrides": [] },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "id": 3,
      "targets": [{ "expr": "sum by (instance) (rate(node_network_receive_bytes_total{device!~\"lo|veth.*|docker.*|br.*\"}[5m]))", "legendFormat": "{{instance}} rx", "refId": "A" }],
      "title": "Host Network Receive",
      "type": "timeseries"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": { "defaults": { "unit": "Bps" }, "overrides": [] },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "id": 4,
      "targets": [{ "expr": "sum by (instance) (rate(node_network_transmit_bytes_total{device!~\"lo|veth.*|docker.*|br.*\"}[5m]))", "legendFormat": "{{instance}} tx", "refId": "A" }],
      "title": "Host Network Transmit",
      "type": "timeseries"
    }
  ],
  "refresh": "30s",
  "schemaVersion": 39,
  "style": "dark",
  "tags": ["iac", "host", "node-exporter"],
  "templating": { "list": [] },
  "time": { "from": "now-6h", "to": "now" },
  "timezone": "",
  "title": "Host Overview (IaC)",
  "uid": "host-overview-iac",
  "version": 1,
  "weekStart": ""
}
JSON

cat > /mnt/user/appdata/grafana/dashboards/containers-overview.json <<'JSON'
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 0,
  "id": null,
  "links": [],
  "liveNow": false,
  "panels": [
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": { "defaults": { "unit": "cores" }, "overrides": [] },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "id": 1,
      "targets": [{ "expr": "sum by (name) (rate(container_cpu_usage_seconds_total{name!=\"\"}[5m]))", "legendFormat": "{{name}}", "refId": "A" }],
      "title": "Container CPU Usage (Cores)",
      "type": "timeseries"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": { "defaults": { "unit": "bytes" }, "overrides": [] },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "id": 2,
      "targets": [{ "expr": "sum by (name) (container_memory_working_set_bytes{name!=\"\"})", "legendFormat": "{{name}}", "refId": "A" }],
      "title": "Container Memory Working Set",
      "type": "timeseries"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": { "defaults": { "unit": "Bps" }, "overrides": [] },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "id": 3,
      "targets": [{ "expr": "sum by (name) (rate(container_network_receive_bytes_total{name!=\"\"}[5m]))", "legendFormat": "{{name}} rx", "refId": "A" }],
      "title": "Container Network Receive",
      "type": "timeseries"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": { "defaults": { "unit": "Bps" }, "overrides": [] },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "id": 4,
      "targets": [{ "expr": "sum by (name) (rate(container_network_transmit_bytes_total{name!=\"\"}[5m]))", "legendFormat": "{{name}} tx", "refId": "A" }],
      "title": "Container Network Transmit",
      "type": "timeseries"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] },
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 16 },
      "id": 5,
      "targets": [{ "expr": "sum by (name) (increase(container_oom_events_total{name!=\"\"}[24h]))", "legendFormat": "{{name}}", "refId": "A" }],
      "title": "Container OOM Events (Last 24h)",
      "type": "timeseries"
    }
  ],
  "refresh": "30s",
  "schemaVersion": 39,
  "style": "dark",
  "tags": ["iac", "containers", "cadvisor"],
  "templating": { "list": [] },
  "time": { "from": "now-6h", "to": "now" },
  "timezone": "",
  "title": "Container Overview (IaC)",
  "uid": "container-overview-iac",
  "version": 1,
  "weekStart": ""
}
JSON

echo "Phase 2 complete."

echo "Starting Phase 3: Docker Compose Stack..."
cat > /mnt/user/appdata/arr-stack/docker-compose.yml <<'EOF'
services:
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun
    labels:
      kuma.gluetun.docker.name: gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - TZ=${TZ}
      - VPN_SERVICE_PROVIDER=${VPN_SERVICE_PROVIDER}
      - VPN_TYPE=${VPN_TYPE}
      - WIREGUARD_PRIVATE_KEY=${WIREGUARD_PRIVATE_KEY}
      - WIREGUARD_ADDRESSES=${WIREGUARD_ADDRESSES}
      - WIREGUARD_PUBLIC_KEY=${WIREGUARD_PUBLIC_KEY}
      - VPN_ENDPOINT_IP=${VPN_ENDPOINT_IP}
      - VPN_ENDPOINT_PORT=${VPN_ENDPOINT_PORT}
      - DNS_ADDRESS=${DNS_ADDRESS}
      - FIREWALL_VPN_INPUT_PORTS=8080,6881
      - FIREWALL_INPUT_PORTS=8080,6881
      - FIREWALL_OUTBOUND_SUBNETS=172.16.0.0/12,${LAN_SUBNET}
      - HTTP_CONTROL_SERVER_ADDRESS=:8000
    ports:
      - "8080:8080"
      - "8001:8000"
      - "6881:6881"
      - "6881:6881/udp"
    volumes:
      - /mnt/user/appdata/gluetun:/gluetun
    restart: unless-stopped

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    labels:
      kuma.qbittorrent.docker.name: qbittorrent
    network_mode: "service:gluetun"
    depends_on:
      - gluetun
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - UMASK=${UMASK}
      - WEBUI_PORT=8080
    volumes:
      - /mnt/user/appdata/qbittorrent:/config
      - /mnt/user/data:/data
    restart: unless-stopped

  sabnzbd:
    image: lscr.io/linuxserver/sabnzbd:latest
    container_name: sabnzbd
    labels:
      kuma.sabnzbd.docker.name: sabnzbd
    ports:
      - "8085:8080"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - UMASK=${UMASK}
    volumes:
      - /mnt/user/appdata/sabnzbd:/config
      - /mnt/user/data:/data
    restart: unless-stopped

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    labels:
      kuma.flaresolverr.docker.name: flaresolverr
    environment:
      - LOG_LEVEL=info
      - LOG_HTML=false
      - CAPTCHA_SOLVER=none
      - TZ=${TZ}
    ports:
      - "8191:8191"
    restart: unless-stopped

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    labels:
      kuma.prowlarr.docker.name: prowlarr
    ports:
      - "9696:9696"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - UMASK=${UMASK}
    volumes:
      - /mnt/user/appdata/prowlarr:/config
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    labels:
      kuma.sonarr.docker.name: sonarr
    ports:
      - "8989:8989"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - UMASK=${UMASK}
    volumes:
      - /mnt/user/appdata/sonarr:/config
      - /mnt/user/data:/data
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    labels:
      kuma.radarr.docker.name: radarr
    ports:
      - "7878:7878"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - UMASK=${UMASK}
    volumes:
      - /mnt/user/appdata/radarr:/config
      - /mnt/user/data:/data
    restart: unless-stopped

  lidarr:
    image: lscr.io/linuxserver/lidarr:latest
    container_name: lidarr
    labels:
      kuma.lidarr.docker.name: lidarr
    ports:
      - "8686:8686"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - UMASK=${UMASK}
    volumes:
      - /mnt/user/appdata/lidarr:/config
      - /mnt/user/data:/data
    restart: unless-stopped

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    labels:
      kuma.bazarr.docker.name: bazarr
    ports:
      - "6767:6767"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - UMASK=${UMASK}
    volumes:
      - /mnt/user/appdata/bazarr:/config
      - /mnt/user/data:/data
    restart: unless-stopped

  recyclarr:
    image: ghcr.io/recyclarr/recyclarr:latest
    container_name: recyclarr
    labels:
      kuma.recyclarr.docker.name: recyclarr
    environment:
      - TZ=${TZ}
    volumes:
      - /mnt/user/appdata/recyclarr:/config
    restart: unless-stopped

  unpackerr:
    image: golift/unpackerr:latest
    container_name: unpackerr
    labels:
      kuma.unpackerr.docker.name: unpackerr
    environment:
      - TZ=${TZ}
      - UN_SONARR_0_URL=http://sonarr:8989
      - UN_RADARR_0_URL=http://radarr:7878
    volumes:
      - /mnt/user/data:/data
    restart: unless-stopped

  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    labels:
      kuma.jellyfin.docker.name: jellyfin
    runtime: nvidia
    ports:
      - "8096:8096"
      - "8920:8920"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - UMASK=${UMASK}
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=all
    volumes:
      - /mnt/user/appdata/jellyfin:/config
      - /mnt/user/data/media:/data/media
    restart: unless-stopped

  jellyseerr:
    image: ghcr.io/seerr-team/seerr:latest
    container_name: jellyseerr
    labels:
      kuma.jellyseerr.docker.name: jellyseerr
    init: true
    user: "1000:1000"
    ports:
      - "5055:5055"
    environment:
      - TZ=${TZ}
    volumes:
      - /mnt/user/appdata/jellyseerr:/app/config
    restart: unless-stopped

  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    labels:
      kuma.homepage.docker.name: homepage
    ports:
      - "3001:3000"
    environment:
      - TZ=${TZ}
      - PUID=${PUID}
      - PGID=${PGID}
      - HOMEPAGE_ALLOWED_HOSTS=${LAN_HOST}:3001
      - HOMEPAGE_VAR_LAN_HOST=${LAN_HOST}
      - HOMEPAGE_VAR_JELLYFIN_KEY=${HOMEPAGE_VAR_JELLYFIN_KEY}
      - HOMEPAGE_VAR_JELLYSEERR_KEY=${HOMEPAGE_VAR_JELLYSEERR_KEY}
      - HOMEPAGE_VAR_PROWLARR_KEY=${HOMEPAGE_VAR_PROWLARR_KEY}
      - HOMEPAGE_VAR_SONARR_KEY=${HOMEPAGE_VAR_SONARR_KEY}
      - HOMEPAGE_VAR_RADARR_KEY=${HOMEPAGE_VAR_RADARR_KEY}
      - HOMEPAGE_VAR_LIDARR_KEY=${HOMEPAGE_VAR_LIDARR_KEY}
      - HOMEPAGE_VAR_BAZARR_KEY=${HOMEPAGE_VAR_BAZARR_KEY}
      - HOMEPAGE_VAR_QBIT_USERNAME=${HOMEPAGE_VAR_QBIT_USERNAME}
      - HOMEPAGE_VAR_QBIT_PASSWORD=${HOMEPAGE_VAR_QBIT_PASSWORD}
      - HOMEPAGE_VAR_SABNZBD_KEY=${HOMEPAGE_VAR_SABNZBD_KEY}
      - HOMEPAGE_VAR_CF_ACCOUNT_ID=${HOMEPAGE_VAR_CF_ACCOUNT_ID}
      - HOMEPAGE_VAR_CF_TUNNEL_ID=${HOMEPAGE_VAR_CF_TUNNEL_ID}
      - HOMEPAGE_VAR_CF_TUNNEL_TOKEN=${HOMEPAGE_VAR_CF_TUNNEL_TOKEN}
      - HOMEPAGE_VAR_NEXTCLOUD_KEY=${HOMEPAGE_VAR_NEXTCLOUD_KEY}
      - HOMEPAGE_VAR_PAPERLESS_KEY=${HOMEPAGE_VAR_PAPERLESS_KEY}
      - HOMEPAGE_VAR_IMMICH_KEY=${HOMEPAGE_VAR_IMMICH_KEY}
      - HOMEPAGE_VAR_GRAFANA_PASSWORD=${HOMEPAGE_VAR_GRAFANA_PASSWORD}
      - HOMEPAGE_VAR_GITEA_KEY=${HOMEPAGE_VAR_GITEA_KEY}
      - HOMEPAGE_VAR_WEATHER_LABEL=${HOMEPAGE_VAR_WEATHER_LABEL}
      - HOMEPAGE_VAR_WEATHER_LAT=${HOMEPAGE_VAR_WEATHER_LAT}
      - HOMEPAGE_VAR_WEATHER_LON=${HOMEPAGE_VAR_WEATHER_LON}
      - HOMEPAGE_VAR_WEATHER_TZ=${HOMEPAGE_VAR_WEATHER_TZ}
      - HOMEPAGE_VAR_WEATHER_UNITS=${HOMEPAGE_VAR_WEATHER_UNITS}
      - HOMEPAGE_VAR_UPTIMEKUMA_SLUG=${HOMEPAGE_VAR_UPTIMEKUMA_SLUG}
    volumes:
      - /mnt/user/appdata/homepage:/app/config
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /mnt/user/data:/data:ro
      - /mnt/cache:/mnt/cache:ro
    restart: unless-stopped

  immich-server:
    container_name: immich_server
    labels:
      kuma.immich_server.docker.name: immich_server
    image: ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}
    mem_limit: 4g
    depends_on:
      - immich-redis
      - immich-postgres
    ports:
      - "2283:2283"
    volumes:
      - ${UPLOAD_LOCATION}:/data
      - /etc/localtime:/etc/localtime:ro
    environment:
      - DB_HOSTNAME=immich_postgres
      - DB_USERNAME=${DB_USERNAME}
      - DB_PASSWORD=${DB_PASSWORD}
      - DB_DATABASE_NAME=${DB_DATABASE_NAME}
      - REDIS_HOSTNAME=immich_redis
    restart: always
    healthcheck:
      disable: false

  immich-machine-learning:
    container_name: immich_machine_learning
    labels:
      kuma.immich_machine_learning.docker.name: immich_machine_learning
    image: ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION:-release}
    volumes:
      - /mnt/user/appdata/immich/model-cache:/cache
    restart: always
    healthcheck:
      disable: false

  immich-redis:
    container_name: immich_redis
    labels:
      kuma.immich_redis.docker.name: immich_redis
    image: docker.io/valkey/valkey:9@sha256:546304417feac0874c3dd576e0952c6bb8f06bb4093ea0c9ca303c73cf458f63
    healthcheck:
      test: redis-cli ping || exit 1
    restart: always

  immich-postgres:
    container_name: immich_postgres
    labels:
      kuma.immich_postgres.docker.name: immich_postgres
    image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23
    environment:
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: ${DB_DATABASE_NAME}
      POSTGRES_INITDB_ARGS: '--data-checksums'
    volumes:
      - /mnt/user/appdata/immich/postgres:/var/lib/postgresql/data
    shm_size: 128mb
    restart: always
    healthcheck:
      disable: false

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    container_name: cadvisor
    labels:
      kuma.cadvisor.docker.name: cadvisor
    ports:
      - "8082:8080"
    command:
      - '--docker_only=true'
      - '--store_container_labels=true'
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:rw
      - /run/docker/containerd/containerd.sock:/run/containerd/containerd.sock:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    restart: unless-stopped

  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    labels:
      kuma.node-exporter.docker.name: node-exporter
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--path.rootfs=/rootfs'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($|/)'
    ports:
      - "9100:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    labels:
      kuma.prometheus.docker.name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - /mnt/user/appdata/prometheus/data:/prometheus
      - /mnt/user/appdata/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
      - /mnt/user/appdata/prometheus/rules:/etc/prometheus/rules:ro
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.retention.time=30d'
    restart: unless-stopped

  alertmanager:
    image: prom/alertmanager:latest
    container_name: alertmanager
    labels:
      kuma.alertmanager.docker.name: alertmanager
    ports:
      - "9093:9093"
    volumes:
      - /mnt/user/appdata/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml
    command:
      - '--config.file=/etc/alertmanager/alertmanager.yml'
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    labels:
      kuma.grafana.docker.name: grafana
    ports:
      - "3005:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
    volumes:
      - /mnt/user/appdata/grafana:/var/lib/grafana
      - /mnt/user/appdata/grafana/provisioning:/etc/grafana/provisioning:ro
      - /mnt/user/appdata/grafana/dashboards:/etc/grafana/dashboards:ro
    restart: unless-stopped

  uptime-kuma:
    image: louislam/uptime-kuma:2
    container_name: uptime-kuma
    labels:
      kuma.uptime-kuma.docker.name: uptime-kuma
    ports:
      - "3006:3001"
    volumes:
      - /mnt/user/appdata/uptime-kuma:/app/data
      - /var/run/docker.sock:/var/run/docker.sock:ro
    restart: unless-stopped

  autokuma:
    image: ghcr.io/bigboot/autokuma:latest
    container_name: autokuma
    labels:
      kuma.autokuma.docker.name: autokuma
      kuma.homelab_alert.notification.name: Homelab Alerts
      kuma.homelab_alert.notification.active: ${AUTOKUMA_ALERT_PROVIDER_ACTIVE}
      kuma.homelab_alert.notification.config: ${AUTOKUMA_ALERT_PROVIDER_CONFIG_JSON}
    depends_on:
      - uptime-kuma
    environment:
      - AUTOKUMA__KUMA__URL=${AUTOKUMA_KUMA_URL}
      - AUTOKUMA__KUMA__USERNAME=${AUTOKUMA_KUMA_USERNAME}
      - AUTOKUMA__KUMA__PASSWORD=${AUTOKUMA_KUMA_PASSWORD}
      - 'AUTOKUMA__DEFAULT_SETTINGS=docker.docker_container: {{container_name}}'
      - 'AUTOKUMA__DOCKER__EXCLUDE_CONTAINER_PATTERNS=^[a-f0-9]{12}_.*_'
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /mnt/user/appdata/autokuma:/data
    restart: unless-stopped

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    labels:
      kuma.cloudflared.docker.name: cloudflared
    network_mode: host
    env_file:
      - /mnt/user/appdata/cloudflared/.env
    command: tunnel --no-autoupdate run
    restart: unless-stopped

EOF

cat > /mnt/user/appdata/homepage/settings.yaml <<'YAML'
title: Home Server
color: slate
headerStyle: boxed
YAML

cat > /mnt/user/appdata/homepage/services.yaml <<'YAML'
- Core:
    - Unraid:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}
        description: Array Management
        icon: unraid
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}
    - Cloudflare Tunnel:
        href: https://one.dash.cloudflare.com/
        description: Edge Tunnel Status
        icon: cloudflare
        widget:
          type: cloudflared
          accountid: "{{HOMEPAGE_VAR_CF_ACCOUNT_ID}}"
          tunnelid: "{{HOMEPAGE_VAR_CF_TUNNEL_ID}}"
          key: "{{HOMEPAGE_VAR_CF_TUNNEL_TOKEN}}"
- Media:
    - Jellyfin:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:8096
        description: Streaming
        icon: jellyfin
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:8096
        widget:
          type: jellyfin
          url: http://jellyfin:8096
          key: "{{HOMEPAGE_VAR_JELLYFIN_KEY}}"
          enableNowPlaying: true
    - Seerr:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:5055
        description: Requests
        icon: jellyseerr
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:5055
        widget:
          type: jellyseerr
          url: http://jellyseerr:5055
          key: "{{HOMEPAGE_VAR_JELLYSEERR_KEY}}"
- Automation:
    - Prowlarr:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:9696
        icon: prowlarr
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:9696
        widget:
          type: prowlarr
          url: http://prowlarr:9696
          key: "{{HOMEPAGE_VAR_PROWLARR_KEY}}"
    - Sonarr:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:8989
        icon: sonarr
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:8989
        widget:
          type: sonarr
          url: http://sonarr:8989
          key: "{{HOMEPAGE_VAR_SONARR_KEY}}"
    - Radarr:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:7878
        icon: radarr
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:7878
        widget:
          type: radarr
          url: http://radarr:7878
          key: "{{HOMEPAGE_VAR_RADARR_KEY}}"
    - Lidarr:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:8686
        icon: lidarr
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:8686
        widget:
          type: lidarr
          url: http://lidarr:8686
          key: "{{HOMEPAGE_VAR_LIDARR_KEY}}"
    - Bazarr:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:6767
        icon: bazarr
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:6767
        widget:
          type: bazarr
          url: http://bazarr:6767
          key: "{{HOMEPAGE_VAR_BAZARR_KEY}}"

- Download:
    - qBittorrent:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:8080
        icon: qbittorrent
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:8080
        widget:
          type: qbittorrent
          url: http://gluetun:8080
          username: "{{HOMEPAGE_VAR_QBIT_USERNAME}}"
          password: "{{HOMEPAGE_VAR_QBIT_PASSWORD}}"
    - SABnzbd:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:8085
        icon: sabnzbd
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:8085
        widget:
          type: sabnzbd
          url: http://sabnzbd:8080
          key: "{{HOMEPAGE_VAR_SABNZBD_KEY}}"
    - FlareSolverr:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:8191
        description: Cloudflare Solver
        icon: flaresolverr
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:8191
    - Gluetun:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:8001
        description: VPN Gateway
        icon: gluetun
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:8001
        widget:
          type: gluetun
          url: http://gluetun:8000

- Personal Cloud:
    - Nextcloud:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:8086
        description: File Sync
        icon: nextcloud
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:8086
        widget:
          type: nextcloud
          url: http://{{HOMEPAGE_VAR_LAN_HOST}}:8086
          key: "{{HOMEPAGE_VAR_NEXTCLOUD_KEY}}"
    - Paperless-ngx:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:8000
        description: Document Scanner
        icon: paperless
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:8000
        widget:
          type: paperlessngx
          url: http://{{HOMEPAGE_VAR_LAN_HOST}}:8000
          key: "{{HOMEPAGE_VAR_PAPERLESS_KEY}}"
    - Immich:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:2283
        description: Photos
        icon: immich
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:2283
        widget:
          type: immich
          url: http://immich-server:2283
          key: "{{HOMEPAGE_VAR_IMMICH_KEY}}"
          version: 2
    - Gitea:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:8929
        description: Source Control & CI/CD
        icon: gitea
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:8929
        widget:
          type: gitea
          url: http://{{HOMEPAGE_VAR_LAN_HOST}}:8929
          key: "{{HOMEPAGE_VAR_GITEA_KEY}}"

- Observability:
    - Grafana:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:3005
        description: Dashboards
        icon: grafana
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:3005
        widget:
          type: grafana
          url: http://grafana:3000
          username: admin
          password: "{{HOMEPAGE_VAR_GRAFANA_PASSWORD}}"
    - Prometheus:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:9090
        description: Metrics & Alerts
        icon: prometheus
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:9090
        widget:
          type: prometheus
          url: http://prometheus:9090
    - Uptime Kuma:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:3006
        description: Endpoint Health Checks
        icon: uptime-kuma
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:3006
        widget:
          type: uptimekuma
          url: http://uptime-kuma:3001
          slug: "{{HOMEPAGE_VAR_UPTIMEKUMA_SLUG}}"
    - cAdvisor:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:8082
        description: Container Metrics
        icon: docker
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:8082
    - Node Exporter:
        href: http://{{HOMEPAGE_VAR_LAN_HOST}}:9100/metrics
        description: Host Metrics Endpoint
        icon: prometheus
        ping: http://{{HOMEPAGE_VAR_LAN_HOST}}:9100
YAML

cat > /mnt/user/appdata/homepage/bookmarks.yaml <<'YAML'
[]
YAML

cat > /mnt/user/appdata/homepage/widgets.yaml <<'YAML'
- datetime:
    text_size: xl
    format:
      dateStyle: short
      timeStyle: short

- openmeteo:
    label: "{{HOMEPAGE_VAR_WEATHER_LABEL}}"
    latitude: "{{HOMEPAGE_VAR_WEATHER_LAT}}"
    longitude: "{{HOMEPAGE_VAR_WEATHER_LON}}"
    timezone: "{{HOMEPAGE_VAR_WEATHER_TZ}}"
    units: "{{HOMEPAGE_VAR_WEATHER_UNITS}}"
    cache: 10

- resources:
    cpu: true
    memory: true
    label: Unraid
- resources:
    disk: /data
    label: Array (Data Share)
- resources:
    disk: /mnt/cache
    label: Cache Drive

- search:
    provider: duckduckgo
    target: _blank
YAML

echo "Phase 3 complete."

echo "Phase 4: Deploying Docker Stack..."
cd /mnt/user/appdata/arr-stack
docker compose --env-file .env pull
docker compose --env-file .env up -d

# qBittorrent shares Gluetun's network namespace via network_mode.
# If Gluetun was recreated, qBittorrent must also be recreated to
# rejoin the new namespace -- compose doesn't always cascade this.
GLUETUN_NS=$(docker exec gluetun ls -la /proc/1/ns/net 2>/dev/null | awk -F'-> ' '{print $2}')
QBIT_NS=$(docker exec qbittorrent ls -la /proc/1/ns/net 2>/dev/null | awk -F'-> ' '{print $2}')
if [ -n "$GLUETUN_NS" ] && [ -n "$QBIT_NS" ] && [ "$GLUETUN_NS" != "$QBIT_NS" ]; then
  echo "Network namespace mismatch detected, recreating qbittorrent..."
  docker compose --env-file .env up -d --force-recreate qbittorrent
fi

QBIT_API_CODE="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/api/v2/app/webapiVersion || true)"
if [ "$QBIT_API_CODE" != "200" ]; then
  echo "qBittorrent API not reachable on port 8080 (HTTP ${QBIT_API_CODE:-ERR}), recreating qbittorrent..."
  docker compose --env-file .env up -d --force-recreate qbittorrent
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
