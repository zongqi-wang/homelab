#!/bin/bash
set -e

mkdir -p /mnt/user/appdata/gitlab/{config,logs,data}
mkdir -p /mnt/user/appdata/gitlab-runner/config

cat > /mnt/user/appdata/gitlab/docker-compose.yml <<'YML'
services:
  gitlab:
    image: gitlab/gitlab-ce:latest
    container_name: gitlab
    hostname: gitlab.local
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://192.168.1.100:8929'
        gitlab_rails['gitlab_shell_ssh_port'] = 2424
        nginx['listen_port'] = 8929
    ports:
      - "8929:8929"
      - "2424:22"
    volumes:
      - /mnt/user/appdata/gitlab/config:/etc/gitlab
      - /mnt/user/appdata/gitlab/logs:/var/log/gitlab
      - /mnt/user/appdata/gitlab/data:/var/opt/gitlab
    shm_size: "256m"
    restart: unless-stopped

  gitlab-runner:
    image: gitlab/gitlab-runner:latest
    container_name: gitlab-runner
    depends_on:
      - gitlab
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /mnt/user/appdata/gitlab-runner/config:/etc/gitlab-runner
    restart: unless-stopped
YML

cd /mnt/user/appdata/gitlab
docker compose pull
docker compose up -d
