# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Infrastructure-as-code for an Unraid-based home lab. Bash deploy scripts that bootstrap directories, write configs, generate docker-compose files, and deploy Docker stacks. **Not** a typical software project -- no build system, no test suite, no package manager.

## Repository Structure

```
homelab/
├── arr-stack/          # Media automation, streaming, photos, observability, dashboard
│   ├── deploy.sh       # Main deploy script
│   └── .env.example    # Template for secrets
├── cloud-stack/        # Nextcloud + Paperless-ngx
│   ├── deploy.sh
│   └── .env.example
└── gitlab/             # GitLab CE + Runner
    ├── deploy.sh
    └── .env.example
```

## Architecture

The Unraid server (192.168.1.100) runs three separate Docker Compose stacks:

1. **arr-stack** (`/mnt/user/appdata/arr-stack/`) -- Gluetun VPN, qBittorrent, SABnzbd, FlareSolverr, Prowlarr, Sonarr, Radarr, Lidarr, Bazarr, Recyclarr, Unpackerr, Jellyfin, Seerr, Immich + Redis + Postgres, cAdvisor, node-exporter, Prometheus, Grafana, Homepage dashboard, Cloudflared tunnel.
2. **cloud-stack** (`/mnt/user/appdata/cloud-stack/`) -- Nextcloud + MariaDB, Paperless-ngx + Postgres + Redis + Gotenberg + Tika.
3. **gitlab** (`/mnt/user/appdata/gitlab/`) -- GitLab CE + GitLab Runner.

## Key Design Constraints

- All media apps share `/mnt/user/data` (host) -> `/data` (container) for hardlinks.
- Only torrent traffic routes through VPN (qBittorrent -> Gluetun).
- Gluetun needs `FIREWALL_OUTBOUND_SUBNETS=172.16.0.0/12,192.168.1.0/24`.
- Unraid ownership: `PUID=99`, `PGID=100`, `UMASK=002` for linuxserver.io containers. Exceptions: Nextcloud (33), MariaDB (999), Immich Postgres (999), Grafana (472), Prometheus (65534), Seerr (1000).
- External access: Jellyfin via Cloudflare Tunnel (outbound-only).

## Secrets Management

**All secrets live in `.env` files (gitignored).** Each stack directory has a `.env.example` template. To deploy:

```bash
cd arr-stack
cp .env.example .env
# Fill in real values
bash deploy.sh
```

Homepage widget keys use `{{HOMEPAGE_VAR_*}}` template syntax -- the actual values are passed as environment variables to the Homepage container from the `.env` file.

## SSH Access

```bash
ssh root@192.168.1.100
```

## Conventions

- Deploy scripts use `set -e` and source a `.env` file from their own directory.
- Each script is self-contained: copy the directory to the server and run `deploy.sh`.
- YAML configs use heredoc syntax. Single-quoted delimiters (`<<'YAML'`) prevent variable expansion; unquoted (`<<EOF`) allow it.
- Edit deploy scripts directly rather than writing separate patch scripts.

## Service Ports

| Service | Port | Notes |
|---------|------|-------|
| Homepage | 3001 | Dashboard |
| qBittorrent | 8080 | Via Gluetun |
| Gluetun API | 8001 | Control server |
| SABnzbd | 8085 | |
| FlareSolverr | 8191 | |
| Prowlarr | 9696 | |
| Sonarr | 8989 | |
| Radarr | 7878 | |
| Lidarr | 8686 | |
| Bazarr | 6767 | |
| Jellyfin | 8096 | |
| Seerr | 5055 | |
| Immich | 2283 | |
| Nextcloud | 8086 | |
| Paperless-ngx | 8000 | |
| GitLab | 8929 | SSH on 2424 |
| Grafana | 3005 | |
| Prometheus | 9090 | |
| cAdvisor | 8082 | |
| cloudflared | N/A | Outbound-only tunnel |
