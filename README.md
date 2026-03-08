# homelab

Infrastructure-as-code for my Unraid home server. Three Docker Compose stacks managed via bash deploy scripts.

## Stacks

| Stack | Services |
|-------|----------|
| **arr-stack** | Gluetun, qBittorrent, SABnzbd, Prowlarr, Sonarr, Radarr, Lidarr, Bazarr, Recyclarr, Unpackerr, Jellyfin, Seerr, Immich, Prometheus, Grafana, Homepage, Cloudflared |
| **cloud-stack** | Nextcloud, MariaDB, Paperless-ngx, Postgres, Redis, Gotenberg, Tika |
| **gitlab** | GitLab CE, GitLab Runner |

## Usage

```bash
cd arr-stack
cp .env.example .env
# Edit .env with your actual secrets
bash deploy.sh
```

Each stack is independent and can be deployed separately.

## Secrets

All sensitive values (API keys, passwords, VPN keys) are stored in `.env` files which are **not committed** to the repo. See `.env.example` in each stack directory for the required variables.
