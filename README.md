# homelab

Infrastructure-as-code for my Unraid home server. Three Docker Compose stacks managed via self-contained bash deploy scripts.

## Architecture

```
Unraid Server (<LAN_HOST>)
├── arr-stack        Media automation, streaming, photos, observability, dashboard
├── cloud-stack      File sync and document management
└── gitlab           Code hosting and CI/CD
```

All stacks run as Docker Compose projects under `/mnt/user/appdata/`. Media apps share a single `/mnt/user/data` mount for hardlink support. Only torrent traffic routes through VPN (qBittorrent via Gluetun). External access is outbound-only via Cloudflare Tunnel.

## Stacks

### arr-stack

Media automation and home dashboard. ~25 containers.

| Category | Services |
|----------|----------|
| Download | Gluetun (VPN), qBittorrent, SABnzbd, FlareSolverr |
| Arr suite | Prowlarr, Sonarr, Radarr, Lidarr, Bazarr, Recyclarr, Unpackerr |
| Streaming | Jellyfin, Seerr |
| Photos | Immich, Valkey, Postgres (pgvecto-rs) |
| Observability | cAdvisor, node-exporter, Prometheus, Grafana |
| Uptime | Uptime Kuma + AutoKuma (Docker label sync), status-page bootstrap |
| Infrastructure | Homepage dashboard, Cloudflared tunnel |

### cloud-stack

| Services |
|----------|
| Nextcloud + MariaDB |
| Paperless-ngx + Postgres + Redis + Gotenberg + Tika |

### gitlab

| Services |
|----------|
| GitLab CE + GitLab Runner |

## Usage

```bash
# Clone and set up a stack
cd arr-stack
cp .env.example .env
vim .env              # fill in real values (including LAN_HOST/LAN_SUBNET, AutoKuma creds, and alert/status-page vars)
bash deploy.sh        # bootstraps dirs, writes configs, deploys containers
```

Each stack is independent. Deploy scripts are self-contained -- copy the directory to the server and run `deploy.sh`.

## Secrets

All sensitive values (API keys, passwords, VPN keys) live in `.env` files which are **gitignored**. Each stack has a `.env.example` template showing required variables.

Homepage widget keys use the `{{HOMEPAGE_VAR_*}}` template syntax -- actual values are injected as container environment variables from the `.env` file.

AutoKuma alerting is configured via `AUTOKUMA_ALERT_PROVIDER_*` and `AUTOKUMA_DEFAULT_NOTIFICATION_NAME_LIST` in `arr-stack/.env`.  
Status page creation is bootstrapped in `arr-stack/deploy.sh` using `UPTIME_KUMA_STATUS_PAGE_*`.
Monitor creation is IaC-driven via `kuma.*` Docker labels, with deploy-time AutoKuma resync/reconciliation in the stack deploy scripts.

## Ports

| Service | Port | Service | Port |
|---------|------|---------|------|
| Homepage | 3001 | Jellyfin | 8096 |
| qBittorrent | 8080 | Seerr | 5055 |
| SABnzbd | 8085 | Immich | 2283 |
| Prowlarr | 9696 | Nextcloud | 8086 |
| Sonarr | 8989 | Paperless-ngx | 8000 |
| Radarr | 7878 | GitLab | 8929 |
| Lidarr | 8686 | Grafana | 3005 |
| Bazarr | 6767 | Prometheus | 9090 |
| Uptime Kuma | 3006 | cAdvisor | 8082 |
