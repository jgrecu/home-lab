---
source: GitHub Repository (README, Dockerfile, FAQ, API docs)
library: WatchState
package: arabcoders/watchstate
topic: deployment-guide
fetched: 2026-07-29T12:00:00Z
official_docs: https://github.com/arabcoders/watchstate
---

# WatchState - Deployment Guide

Self-hosted service to sync Plex, Jellyfin, and Emby play state without relying on third-party external services.

## Container Image

**Primary Registry (GHCR):**
```
ghcr.io/arabcoders/watchstate:latest
```

**Docker Hub (also available):**
```
arabcoders/watchstate:latest
```

**Tags:**
- `latest` - Stable release
- `dev` - Development/nightly builds

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 8080 | TCP | WebUI + API (HTTP server via FrankenPHP/Caddy) |

The container exposes only port **8080** which serves both the WebUI and the REST API.

## Health Check

**Endpoint:** `GET /v1/api/system/healthcheck`

**Docker HEALTHCHECK (built into image):**
```
HEALTHCHECK --interval=10s --timeout=3s CMD curl -f http://localhost:8080/v1/api/system/healthcheck || exit 1
```

For Kubernetes liveness/readiness probes:
```yaml
livenessProbe:
  httpGet:
    path: /v1/api/system/healthcheck
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 3
readinessProbe:
  httpGet:
    path: /v1/api/system/healthcheck
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
  timeoutSeconds: 3
```

## Persistent Storage

**Single volume required:** `/config`

| Mount Path | Purpose | Access Mode |
|-----------|---------|-------------|
| `/config` | All application data (database, config, logs, backups, cache) | ReadWrite |

The `/config` directory contains:
- `/config/db/` - SQLite database files
- `/config/config/` - Configuration files (`.env`, backend configs)
- `/config/backup/` - Backup files
- `/config/cache/` - Cache data
- `/config/logs/` - Log files
- `/config/webhooks/` - Webhook dump files
- `/config/debug/` - Debug files
- `/config/profiler/` - Profiler data

**Recommended PVC size:** 1-5Gi depending on library size.

## Environment Variables

### Container-Level Environment Variables (set in compose/deployment)

| Key | Type | Description | Default |
|-----|------|-------------|---------|
| `DISABLE_CRON` | integer | Disable included Task Scheduler | `0` |
| `DISABLE_CACHE` | integer | Disable included Cache Server (Redis) | `0` |

### Application Environment Variables (set via WebUI `Env` page or `/config/config/.env`)

| Key | Type | Description | Default |
|-----|------|-------------|---------|
| `WS_TZ` | string | Timezone for WatchState | `UTC` |
| `WS_DATA_PATH` | string | Data directory path | `/config` |
| `WS_CACHE_URL` | string | External Redis URL (if DISABLE_CACHE=1) | (internal Redis) |
| `WS_SECURE_API_ENDPOINTS` | bool | Require API key for all endpoints | `false` |
| `WS_TRUST_PROXY` | bool | Trust X-Forwarded-For header | `false` |
| `WS_TRUST_LOCAL` | bool | Trust all local network requests (bypass auth) | `false` |
| `WS_TRUST_HEADER` | string | Custom header for proxy trust | `X-Forwarded-For` |
| `WS_CRON_IMPORT_AT` | cron | Import task schedule | Every 1 hour |
| `WS_CRON_EXPORT_AT` | cron | Export task schedule | Every 1.5 hours |
| `WS_CRON_IMPORT_ARGS` | string | Extra args for import task | `-v` |
| `WS_CRON_EXPORT_ARGS` | string | Extra args for export task | `-v` |
| `WS_DB_MODE` | string | Database mode (`MEMORY` for speed) | (default/disk) |
| `WS_MEDIA_HEALTH_CHECK_FILES` | bool | Enable local file checks in media health | `false` |

### External Redis Configuration

If using an external Redis (set `DISABLE_CACHE=1`):
```
WS_CACHE_URL=redis://host:port?password=your_password&db=db_number
```

## User/Permissions

The container is **rootless**. The `user` directive MUST match the owner of the mounted `/config` directory.

```yaml
# In compose.yaml or Kubernetes securityContext
user: "1000:1000"
```

For Kubernetes:
```yaml
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
```

## Backend Configuration (Plex, Jellyfin, Emby)

Backends are configured via the **WebUI** at `http://<host>:8080` after first launch.

### First Launch
1. Access WebUI at port 8080
2. Create initial admin user (one-time operation)
3. Add backends via the UI

### Supported Backends
- **Plex** - Requires Plex token; PlexPass required for webhooks
- **Jellyfin** - Requires username:password (auto-generates OAuth token); Webhook plugin needed for webhooks
- **Emby** - Requires username:password (auto-generates OAuth token); Emby Premiere required for webhooks

### Sync Modes
- **Two-way sync** - Both import and export enabled on all backends
- **One-way sync** - Import from source, export to target only

### Import Methods
1. **Scheduled Tasks** - Automatic cron-based import/export (default: import every 1h, export every 1.5h)
2. **On demand** - Manual import/export via WebUI
3. **Webhooks** - Real-time event-driven sync (recommended alongside scheduled tasks)

### Webhook URL
```
https://your-watchstate-url/v1/api/webhook
```
If `WS_SECURE_API_ENDPOINTS` is enabled:
```
https://your-watchstate-url/v1/api/webhook?apikey=[your_api_key]
```

## Helm Chart

**No official Helm chart exists.** The project provides only Docker/compose deployment.

For Kubernetes deployment, you'll need to create a custom HelmRelease using a generic chart (like bjw-s/app-template) or write raw manifests.

## Docker Compose Reference

```yaml
services:
  watchstate:
    image: ghcr.io/arabcoders/watchstate:latest
    user: "${UID:-1000}:${UID:-1000}"
    container_name: watchstate
    restart: unless-stopped
    ports:
      - "8080:8080"
    environment:
      - WS_TZ=UTC
      # - DISABLE_CRON=0
      # - DISABLE_CACHE=0
    volumes:
      - ./data:/config:rw
```

## Hardware Acceleration (Optional)

For video playback/transcoding features:
```yaml
devices:
  - /dev/dri:/dev/dri
group_add:
  - "44"   # video group
  - "105"  # render group
volumes:
  - /storage/media:/media:ro  # mount media for playback
```

## API Endpoints (Key ones)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/api/system/healthcheck` | GET | Health check |
| `/v1/api/system/version` | GET | Version info |
| `/v1/api/webhook` | POST/PUT | Webhook receiver (for all backends) |
| `/v1/api/backends` | GET | List configured backends |
| `/v1/api/backends` | POST | Add new backend |
| `/v1/api/tasks` | GET | List scheduled tasks |
| `/v1/api/history` | GET | Browse watch history |
| `/v1/api/system/env` | GET | List environment variables |

## Authentication

- First access requires creating an admin user
- API supports: API key header (`X-APIKEY`), query param (`?apikey=`), or Bearer token
- Can disable auth for local networks with `WS_TRUST_LOCAL=true`

## Architecture Notes

- Built with PHP (FrankenPHP - Caddy + PHP combined binary)
- Embedded Redis for caching (can be disabled for external Redis)
- SQLite database (stored in `/config/db/`)
- Built-in task scheduler (cron-like, can be disabled)
- Frontend is a pre-built static Nuxt.js app
