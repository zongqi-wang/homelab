# homelab

Infrastructure-as-code for my Unraid home server. Three Docker Compose stacks managed via self-contained bash deploy scripts.

![Homepage Dashboard](docs/homepage.png)

## Architecture

```
Unraid Server (<LAN_HOST>)
├── arr-stack        Media automation, streaming, photos, observability, dashboard
├── cloud-stack      File sync and document management
└── gitlab           Code hosting and CI/CD (Gitea + act_runner)
```

All stacks run as Docker Compose projects under `/mnt/user/appdata/`. Media apps share a single `/mnt/user/data` mount for hardlink support. Only torrent traffic routes through VPN (qBittorrent via Gluetun). External access is outbound-only via Cloudflare Tunnel.

## Stacks

### arr-stack

Media automation, home dashboard, and full observability. ~30 containers.

| Category | Services |
|----------|----------|
| Download | Gluetun (WireGuard VPN), qBittorrent, SABnzbd, FlareSolverr |
| Arr suite | Prowlarr, Sonarr, Radarr, Lidarr, Bazarr, Recyclarr, Unpackerr |
| Streaming | Jellyfin (NVIDIA NVENC hw transcoding), Seerr |
| Photos | Immich, Valkey, Postgres (pgvecto-rs) |
| Observability | cAdvisor, node-exporter, Prometheus, Alertmanager, Grafana |
| Uptime | Uptime Kuma v2 + AutoKuma (Docker label-driven monitor sync) |
| Infrastructure | Homepage dashboard, Cloudflared tunnel |

### cloud-stack

| Services |
|----------|
| Nextcloud + MariaDB |
| Paperless-ngx + Postgres + Redis + Gotenberg + Tika |

### gitlab (Gitea)

| Services |
|----------|
| Gitea (GitHub Actions-compatible CI/CD) + act_runner |

## Usage

```bash
# Clone and set up a stack
cd arr-stack
cp .env.example .env
vim .env              # fill in real values
bash deploy.sh        # bootstraps dirs, writes configs, deploys containers
```

Each stack is independent. Deploy scripts are self-contained -- copy the directory to the server and run `deploy.sh`.

## Secrets

All sensitive values (API keys, passwords, VPN keys) live in `.env` files which are **gitignored**. Each stack has a `.env.example` template showing required variables.

Homepage widget keys use `{{HOMEPAGE_VAR_*}}` template syntax -- actual values are injected as container environment variables from the `.env` file.

## Observability

Three layers of monitoring:

| Layer | Tool | What it does |
|-------|------|-------------|
| **Container health** | Uptime Kuma + AutoKuma | Docker container up/down monitoring, auto-provisioned from `kuma.*` labels |
| **Resource metrics** | Prometheus + cAdvisor + node-exporter | CPU, memory, network, OOM events (30d retention) |
| **Alerting** | Alertmanager + Discord | Fires on OOM kills, high memory/CPU, container down |
| **Dashboards** | Grafana | Host Overview + Container Overview (IaC-provisioned) |

Alert rules: `HostCPUUsageHigh`, `HostMemoryUsageHigh`, `ContainerDown`, `ContainerOOM`, `ContainerMemoryHigh`, `ContainerCPUHigh`

## Ports

| Service | Port | Service | Port |
|---------|------|---------|------|
| Homepage | 3001 | Jellyfin | 8096 |
| qBittorrent | 8080 | Seerr | 5055 |
| SABnzbd | 8085 | Immich | 2283 |
| Prowlarr | 9696 | Nextcloud | 8086 |
| Sonarr | 8989 | Paperless-ngx | 8000 |
| Radarr | 7878 | Gitea | 8929 |
| Lidarr | 8686 | Grafana | 3005 |
| Bazarr | 6767 | Prometheus | 9090 |
| Uptime Kuma | 3006 | Alertmanager | 9093 |
| cAdvisor | 8082 | node-exporter | 9100 |
