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

echo "Starting Phase 1: Bootstrap Directories..."
mkdir -p /mnt/user/data/downloads/torrents/{incomplete,complete}
mkdir -p /mnt/user/data/downloads/usenet/{incomplete,complete}
mkdir -p /mnt/user/data/media/{movies,tv,anime,music}
mkdir -p /mnt/user/appdata/{gluetun,qbittorrent,sabnzbd,prowlarr,sonarr,radarr,lidarr,bazarr,recyclarr,unpackerr,jellyfin,jellyseerr,tautulli,arr-stack,node-exporter}
mkdir -p /mnt/user/appdata/homepage
mkdir -p /mnt/user/appdata/cloudflared
mkdir -p /mnt/user/data/photos/library
mkdir -p /mnt/user/appdata/immich/{postgres,model-cache}
mkdir -p /mnt/user/appdata/grafana
mkdir -p /mnt/user/appdata/grafana/provisioning/datasources
mkdir -p /mnt/user/appdata/grafana/provisioning/dashboards
mkdir -p /mnt/user/appdata/grafana/dashboards
mkdir -p /mnt/user/appdata/prometheus/{data,rules}

chown -R 99:100 /mnt/user/data/downloads /mnt/user/data/media
chmod -R ug+rwX,o+rx /mnt/user/data/downloads /mnt/user/data/media
for d in gluetun qbittorrent sabnzbd prowlarr sonarr radarr lidarr bazarr recyclarr unpackerr jellyfin tautulli arr-stack homepage cloudflared; do
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

cat > /mnt/user/appdata/prometheus/rules/container-health.yml <<'YAML'
groups:
  - name: container-health
    rules:
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
      - FIREWALL_OUTBOUND_SUBNETS=172.16.0.0/12,192.168.1.0/24
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
    environment:
      - TZ=${TZ}
    volumes:
      - /mnt/user/appdata/recyclarr:/config
    restart: unless-stopped

  unpackerr:
    image: golift/unpackerr:latest
    container_name: unpackerr
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
    ports:
      - "8096:8096"
      - "8920:8920"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - UMASK=${UMASK}
    volumes:
      - /mnt/user/appdata/jellyfin:/config
      - /mnt/user/data/media:/data/media
    restart: unless-stopped

  jellyseerr:
    image: ghcr.io/seerr-team/seerr:latest
    container_name: jellyseerr
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
    ports:
      - "3001:3000"
    environment:
      - TZ=${TZ}
      - PUID=${PUID}
      - PGID=${PGID}
      - HOMEPAGE_ALLOWED_HOSTS=192.168.1.100:3001
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
    volumes:
      - /mnt/user/appdata/homepage:/app/config
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /mnt/user/data:/data:ro
      - /mnt/cache:/mnt/cache:ro
    restart: unless-stopped

  immich-server:
    container_name: immich_server
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
    image: ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION:-release}
    volumes:
      - /mnt/user/appdata/immich/model-cache:/cache
    restart: always
    healthcheck:
      disable: false

  immich-redis:
    container_name: immich_redis
    image: docker.io/valkey/valkey:9@sha256:546304417feac0874c3dd576e0952c6bb8f06bb4093ea0c9ca303c73cf458f63
    healthcheck:
      test: redis-cli ping || exit 1
    restart: always

  immich-postgres:
    container_name: immich_postgres
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
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--path.rootfs=/rootfs'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($|/)'
    expose:
      - "9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
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

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3005:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
    volumes:
      - /mnt/user/appdata/grafana:/var/lib/grafana
      - /mnt/user/appdata/grafana/provisioning:/etc/grafana/provisioning:ro
      - /mnt/user/appdata/grafana/dashboards:/etc/grafana/dashboards:ro
    restart: unless-stopped

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
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
- Media:
    - Jellyfin:
        href: http://192.168.1.100:8096
        description: Streaming
        icon: jellyfin
        ping: http://192.168.1.100:8096
        widget:
          type: jellyfin
          url: http://192.168.1.100:8096
          key: "{{HOMEPAGE_VAR_JELLYFIN_KEY}}"
          enableNowPlaying: true
    - Jellyseerr:
        href: http://192.168.1.100:5055
        description: Requests
        icon: jellyseerr
        ping: http://192.168.1.100:5055
        widget:
          type: jellyseerr
          url: http://192.168.1.100:5055
          key: "{{HOMEPAGE_VAR_JELLYSEERR_KEY}}"

- Arr Stack:
    - Prowlarr:
        href: http://192.168.1.100:9696
        icon: prowlarr
        ping: http://192.168.1.100:9696
        widget:
          type: prowlarr
          url: http://192.168.1.100:9696
          key: "{{HOMEPAGE_VAR_PROWLARR_KEY}}"
    - Sonarr:
        href: http://192.168.1.100:8989
        icon: sonarr
        ping: http://192.168.1.100:8989
        widget:
          type: sonarr
          url: http://192.168.1.100:8989
          key: "{{HOMEPAGE_VAR_SONARR_KEY}}"
    - Radarr:
        href: http://192.168.1.100:7878
        icon: radarr
        ping: http://192.168.1.100:7878
        widget:
          type: radarr
          url: http://192.168.1.100:7878
          key: "{{HOMEPAGE_VAR_RADARR_KEY}}"
    - Lidarr:
        href: http://192.168.1.100:8686
        icon: lidarr
        ping: http://192.168.1.100:8686
        widget:
          type: lidarr
          url: http://192.168.1.100:8686
          key: "{{HOMEPAGE_VAR_LIDARR_KEY}}"
    - Bazarr:
        href: http://192.168.1.100:6767
        icon: bazarr
        ping: http://192.168.1.100:6767
        widget:
          type: bazarr
          url: http://192.168.1.100:6767
          key: "{{HOMEPAGE_VAR_BAZARR_KEY}}"

- Download:
    - qBittorrent:
        href: http://192.168.1.100:8080
        icon: qbittorrent
        ping: http://192.168.1.100:8080
        widget:
          type: qbittorrent
          url: http://192.168.1.100:8080
          username: "{{HOMEPAGE_VAR_QBIT_USERNAME}}"
          password: "{{HOMEPAGE_VAR_QBIT_PASSWORD}}"
    - SABnzbd:
        href: http://192.168.1.100:8085
        icon: sabnzbd
        ping: http://192.168.1.100:8085
        widget:
          type: sabnzbd
          url: http://192.168.1.100:8085
          key: "{{HOMEPAGE_VAR_SABNZBD_KEY}}"
    - FlareSolverr:
        href: http://192.168.1.100:8191
        description: Proxy
        icon: flaresolverr
        ping: http://192.168.1.100:8191
    - Gluetun:
        href: http://192.168.1.100:8001
        description: VPN Gateway
        icon: gluetun
        ping: http://192.168.1.100:8001
        widget:
          type: gluetun
          url: http://192.168.1.100:8001
    - Cloudflare Tunnel:
        href: https://one.dash.cloudflare.com/
        description: Tunnel status
        icon: cloudflare
        widget:
          type: cloudflared
          accountid: "{{HOMEPAGE_VAR_CF_ACCOUNT_ID}}"
          tunnelid: "{{HOMEPAGE_VAR_CF_TUNNEL_ID}}"
          key: "{{HOMEPAGE_VAR_CF_TUNNEL_TOKEN}}"

- Personal Cloud:
    - Nextcloud:
        href: http://192.168.1.100:8086
        description: File Sync
        icon: nextcloud
        ping: http://192.168.1.100:8086
        widget:
          type: nextcloud
          url: http://192.168.1.100:8086
          key: "{{HOMEPAGE_VAR_NEXTCLOUD_KEY}}"
    - Paperless-ngx:
        href: http://192.168.1.100:8000
        description: Document Scanner
        icon: paperless
        ping: http://192.168.1.100:8000
        widget:
          type: paperlessngx
          url: http://192.168.1.100:8000
          key: "{{HOMEPAGE_VAR_PAPERLESS_KEY}}"
    - Immich:
        href: http://192.168.1.100:2283
        description: Photos
        icon: immich
        ping: http://192.168.1.100:2283
        widget:
          type: immich
          url: http://192.168.1.100:2283
          key: "{{HOMEPAGE_VAR_IMMICH_KEY}}"
          version: 2

- Observability:
    - Grafana:
        href: http://192.168.1.100:3005
        description: Dashboards
        icon: grafana
        ping: http://192.168.1.100:3005
        widget:
          type: grafana
          url: http://grafana:3000
          username: admin
          password: "{{HOMEPAGE_VAR_GRAFANA_PASSWORD}}"
    - Prometheus:
        href: http://192.168.1.100:9090
        description: Metrics & Alerts
        icon: prometheus
        ping: http://192.168.1.100:9090
        widget:
          type: prometheus
          url: http://prometheus:9090

YAML

cat > /mnt/user/appdata/homepage/widgets.yaml <<'YAML'
- resources:
    cpu: true
    memory: true
    label: Unraid
- resources:
    disk: /data
    label: Array (24TB)
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
echo "Stack deployed successfully!"
