---
source: GitHub Repository (FAQ.md, webhooks.md)
library: WatchState
package: arabcoders/watchstate
topic: configuration-and-webhooks
fetched: 2026-07-29T12:00:00Z
official_docs: https://github.com/arabcoders/watchstate/blob/master/FAQ.md
---

# WatchState - Configuration & Webhooks

## Webhook Configuration

### Generic Webhook URL (Single URL for all backends/users)

```
https://your-watchstate-url/v1/api/webhook
```

With secure API endpoints enabled:
```
https://your-watchstate-url/v1/api/webhook?apikey=[api_key]
```

Get API key via WebUI: More > Terminal > type `system:apikey`

### Plex Webhook Setup (PlexPass Required)
1. Plex Web UI > Settings > Your Account > Webhooks > Add Webhook
2. Enter the webhook URL
3. Save Changes

### Jellyfin Webhook Setup (Free - Plugin Required)
1. Dashboard > Plugins > Catalog > Install "Webhook" (under Notifications)
2. Restart Jellyfin
3. Plugins > Webhook > Add Generic Destination
4. Configure:
   - Webhook URL: your WatchState webhook URL
   - Notification Types: Item Added, User Data Saved, Playback Start, Playback Stop
   - User Filter: Select all users
   - Item Type: Movies and Episodes
   - Toggle: Send All Properties, Trim whitespace, Do not send when empty
   - Add Request Header: `Content-Type: application/json`

### Emby Webhook Setup (Emby Premiere Required)
1. Server > Webhooks (or Manage Server > Notifications > Webhooks)
2. Add Webhook:
   - URL: your WatchState webhook URL
   - Request Content Type: `application/json`
   - Events: New Media Added, Playback, Mark Played, Mark Unplayed
   - Limit User Events to: Select all users

### Automated Webhook Registration (Easiest)
Navigate to Backends in WebUI > Click "Add Webhook" button on backend card > Click "Add/Update Webhook"

## Scheduled Tasks

Default schedules:
- **Import**: Every 1 hour
- **Export**: Every 1 hour 30 minutes

Customize via Tasks page > click timer row > redirects to Env page for cron expression.

Even with webhooks enabled, keep scheduled tasks running (e.g., every 12-24 hours) as webhooks aren't 100% reliable.

## Timezone Configuration

All components MUST use the same timezone:
- WatchState: Set `WS_TZ` via Configuration > Env
- Docker fallback: Set `TZ` in compose.yaml
- Plex/Jellyfin/Emby: Must match WatchState timezone
- Host: Ensure NTP is enabled and clock is correct

## External Authentication (Reverse Proxy)

If using external auth (e.g., Authelia, Authentik):
- `WS_TRUST_PROXY=true` - Trust X-Forwarded-For header
- `WS_TRUST_LOCAL=true` - Trust all local network requests

Trusted local networks:
- 10.0.0.0/8
- 127.0.0.1/32
- 172.16.0.0/12
- 192.168.0.0/16
- ::1/128

## External Cache Server

To use external Redis instead of built-in:
1. Set `DISABLE_CACHE=1` in container environment
2. Set `WS_CACHE_URL=redis://host:port?password=your_password&db=db_number`
3. Restart container

Only Redis and API-compatible alternatives are supported.

## Multi-User Support (Identities)

WatchState supports multiple users via "identities". Each identity can have its own set of backends and sync configuration. See the identities guide for setup.

## Common Issues

### Container Crashing on Startup
- Usually permissions issue - container is rootless
- Check: `stat data/config/ | grep 'Uid:'`
- Fix: Set `user:` in compose to match directory owner UID:GID

### HTTP/2-3 Errors with HTTPS Backends
- Backend > Edit > Additional options > `client.http_version` = `1.0`

### Request Timeouts
- Backend > Edit > Additional options > `client.timeout` = `600`

### Corrupt SQLite Database
```bash
docker exec -ti watchstate console db:repair /config/db/watchstate_v01.db
```

### Speed Up Sync Operations
- Set `WS_DB_MODE=MEMORY` (loads entire DB into RAM - requires sufficient memory)

### Reduce Backend Load
- Add `--sync-requests` to task args (e.g., `WS_CRON_IMPORT_ARGS=-v --sync-requests`)
- This switches from async to synchronous requests (slower but less load)
