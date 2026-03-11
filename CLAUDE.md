# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Infrastructure-as-code for an Unraid-based home lab. Bash deploy scripts that bootstrap directories, write configs, generate docker-compose files, and deploy Docker stacks. **Not** a typical software project -- no build system, no test suite, no package manager.

## Repository Structure

```
homelab/
├── arr-stack/          # Media automation, streaming, photos, observability, dashboard
│   ├── deploy.sh       # Main deploy script (~30 containers)
│   └── .env.example    # Template for secrets
├── cloud-stack/        # Nextcloud + Paperless-ngx
│   ├── deploy.sh
│   └── .env.example
├── gitlab/             # Gitea + act_runner (replaced GitLab)
│   ├── deploy.sh
│   └── .env.example
└── docs/               # Screenshots and assets
```

## Architecture

The Unraid server runs three separate Docker Compose stacks:

1. **arr-stack** (`/mnt/user/appdata/arr-stack/`) -- Gluetun VPN, qBittorrent, SABnzbd, FlareSolverr, Prowlarr, Sonarr, Radarr, Lidarr, Bazarr, Recyclarr, Unpackerr, Jellyfin (NVIDIA NVENC), Seerr, Immich + Valkey + Postgres, cAdvisor, node-exporter, Prometheus, Alertmanager, Grafana, Uptime Kuma + AutoKuma, Homepage dashboard, Cloudflared tunnel.
2. **cloud-stack** (`/mnt/user/appdata/cloud-stack/`) -- Nextcloud + MariaDB, Paperless-ngx + Postgres + Redis + Gotenberg + Tika.
3. **gitlab** (`/mnt/user/appdata/gitlab/`) -- Gitea + act_runner (GitHub Actions-compatible CI/CD).

## Key Design Constraints

- All media apps share `/mnt/user/data` (host) -> `/data` (container) for hardlinks.
- Only torrent traffic routes through VPN (qBittorrent -> Gluetun).
- Gluetun needs `FIREWALL_OUTBOUND_SUBNETS=172.16.0.0/12,192.168.1.0/24`.
- Unraid ownership: `PUID=99`, `PGID=100`, `UMASK=002` for linuxserver.io containers. Exceptions: Nextcloud (33), MariaDB (999), Immich Postgres (999), Grafana (472), Prometheus (65534), Seerr (1000).
- External access: Jellyfin via Cloudflare Tunnel (outbound-only).
- Jellyfin uses NVIDIA GTX 1660 Ti for hardware transcoding (`runtime: nvidia`).

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
ssh root@<UNRAID_HOST>
```

## Conventions

- Deploy scripts use `set -e` and source a `.env` file from their own directory.
- Each script is self-contained: copy the directory to the server and run `deploy.sh`.
- YAML configs use heredoc syntax. Single-quoted delimiters (`<<'YAML'`) prevent variable expansion; unquoted (`<<EOF`) allow it.
- Edit deploy scripts directly rather than writing separate patch scripts.
- The `gitlab/` directory name is kept for path compatibility even though it now runs Gitea.

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
| Jellyfin | 8096 | NVIDIA NVENC hw transcoding |
| Seerr | 5055 | |
| Immich | 2283 | 4GB mem_limit |
| Nextcloud | 8086 | |
| Paperless-ngx | 8000 | |
| Gitea | 8929 | SSH on 2424 |
| Grafana | 3005 | |
| Prometheus | 9090 | |
| Alertmanager | 9093 | Discord webhook |
| Uptime Kuma | 3006 | v2 with AutoKuma |
| cAdvisor | 8082 | |
| node-exporter | 9100 | |
| UpSnap | 8090 | Wake-on-LAN (host network) |

## Workstation MAC Addresses (for WOL)

- **Ethernet**: `18:c0:4d:8c:c3:b1` (preferred for WOL)
- **WiFi**: `c8:e2:65:fe:68:34`
| cloudflared | N/A | Outbound-only tunnel |

## Deployment

- Best practice: run `deploy.sh` from the arr-stack dir on the server itself (`/mnt/user/appdata/arr-stack/`).
- Remote deploy: `scp arr-stack/deploy.sh arr-stack/.env root@<UNRAID_HOST>:/mnt/user/appdata/arr-stack/ && ssh root@<UNRAID_HOST> "cd /mnt/user/appdata/arr-stack && bash deploy.sh"`
- After deploying, verify with: `docker ps --format 'table {{.Names}}\t{{.Status}}'`
- Deploy script has a namespace mismatch safeguard: if Gluetun is recreated, qBittorrent is auto-recreated to rejoin the network namespace.

## Permission Gotchas

- Never `chown -R` broad paths like `/mnt/user/appdata` or `/mnt/user/data` -- this breaks other stacks' ownership (Nextcloud=33, MariaDB=999, Paperless Postgres=999).
- Each deploy script only chowns its own directories.
- Nextcloud MariaDB data (`/mnt/user/appdata/nextcloud-db`) must be owned by 999:999 -- if broken, Nextcloud returns HTTP 500 with "Can't read dir" in logs.
- Seerr (formerly Jellyseerr) runs as UID 1000, needs `init: true` and `user: "1000:1000"` in compose.
- Prometheus runs as `nobody` (65534) -- its entire config/data tree must be owned by 65534:65534.

## Unraid-Specific

- cAdvisor needs `/run/docker/containerd/containerd.sock:/run/containerd/containerd.sock:ro` on Unraid (non-standard containerd socket path).
- cAdvisor needs `--docker_only=true --store_container_labels=true` to expose container `name` labels in metrics.
- qBittorrent v5.x: set `WebUI\Address=0.0.0.0` in config to bind IPv4 (Gluetun disables IPv6). CSRF protection can be disabled for LAN-only setups. Failed login attempts trigger temporary IP bans -- restart qBittorrent to clear.
- qBittorrent uses `network_mode: "service:gluetun"` -- if Gluetun is recreated, qBittorrent MUST also be recreated (different network namespace = ECONNRESET). The deploy script handles this automatically.
- Homepage resource widget for cache drive needs explicit `/mnt/cache:/mnt/cache:ro` volume mount and `disk: /mnt/cache` in widgets.yaml.
- Uptime Kuma Docker monitors need the Docker socket mounted AND a Docker Host configured in Settings > Docker Hosts.

## Observability Notes

- Prometheus alert rules: avoid `metric_name>0` inside PromQL label matchers `{}` -- this is invalid syntax. Use `and metric_name > 0` as a separate clause instead.
- AutoKuma v2 + Uptime Kuma v2: `notification_name_list` Docker labels don't work (API incompatibility). Link notifications to monitors via SQLite instead.
- Uptime Kuma monitors created by AutoKuma need `docker_host = 1` set via SQLite: `sqlite3 /app/data/kuma.db "UPDATE monitor SET docker_host = 1 WHERE type = 'docker';"`
- Alertmanager v0.27+ supports `discord_configs` natively -- no adapter container needed.

## Git

- Never include `Co-Authored-By` lines in commit messages.
- Two remotes: `origin` (GitHub) and `gitea` (local Gitea instance).
- Push to both: `git push origin main && git push gitea main`
