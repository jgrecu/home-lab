# Arr-Stack Monitoring Proposal

## Current State

Currently deployed arr-stack applications:
- **Radarr** - Movie collection manager
- **Sonarr** - TV series collection manager  
- **Prowlarr** - Indexer manager/proxy
- **Bazarr** - Subtitle manager

**Monitoring Gap:** None of these applications expose native Prometheus metrics endpoints. We cannot currently monitor:
- Queue sizes and download progress
- Disk space usage and health
- Indexer statistics and success rates
- API response times
- Application health beyond basic HTTP probes

## Solution: Exportarr

**Project:** https://github.com/onedr0p/exportarr  
**Purpose:** Prometheus exporter for *arr applications (Radarr, Sonarr, Lidarr, Prowlarr, Readarr, Bazarr, Whisparr)

### What Exportarr Provides

**Metrics exposed via `/metrics` endpoint:**
- Queue status (downloading, pending, completed)
- System information (disk space, memory, CPU)
- Application statistics (movies/shows/tracks managed)
- Indexer performance (via Prowlarr)
- Health check status
- API performance metrics

**Configuration:**
- Requires API key from each *arr application
- Each exporter instance monitors one application
- Configurable via environment variables
- Optional enhanced metrics via `ENABLE_ADDITIONAL_METRICS` flag

### Deployment Architecture Considerations

**Key constraint from Exportarr documentation:**
> "This exporter will not gather metrics from all apps at once. You will need an `exportarr` instance for each app."

This means we must deploy 4 separate exportarr instances (one per arr-stack app).

## Recommended Approach: Sidecar Pattern

**Deploy exportarr as a sidecar container in each arr-stack HelmRelease.**

### Architecture

```yaml
# Example: Radarr with Exportarr sidecar
controllers:
  radarr:
    containers:
      app:
        # Main Radarr container
        image: lscr.io/linuxserver/radarr:latest
        ports:
          - containerPort: 7878
      
      exportarr:
        # Exportarr sidecar
        image: ghcr.io/onedr0p/exportarr:latest
        env:
          PORT: "9707"
          URL: "http://localhost:7878"
          APIKEY: "<radarr-api-key>"
          ENABLE_ADDITIONAL_METRICS: "true"
        ports:
          - containerPort: 9707

service:
  app:
    ports:
      http: 7878
      metrics: 9707  # Exportarr metrics port
```

**ServiceMonitor per app:**
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: radarr
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: radarr
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
```

### Pros of Sidecar Pattern

1. **Isolation** - Each exporter is co-located with its target app, ensuring metrics survive app restarts
2. **Network locality** - Exportarr uses `localhost` to connect to the arr-stack app (no cross-namespace traffic)
3. **Security** - API keys stored per-app, reducing blast radius of credential exposure
4. **Debugging** - Easy to troubleshoot metrics for a single app without affecting others
5. **Resource control** - Each exporter can have independent resource limits
6. **Follows best practices** - Sidecar pattern is standard for metrics exporters (e.g., CloudSQL proxy, Envoy)

### Cons of Sidecar Pattern

1. **Resource overhead** - 4 additional containers (estimated ~50MB memory + 10m CPU each)
2. **Configuration duplication** - Similar exportarr config repeated across 4 HelmReleases
3. **Slightly higher complexity** - 4 ServiceMonitors to maintain instead of 1

## Alternative Approach: Centralized Exporter (Not Recommended)

Deploy a single exportarr instance that attempts to scrape all 4 apps.

### Why Not Recommended

1. **Violates Exportarr design** - Documentation explicitly states one instance per app
2. **Configuration complexity** - Would require complex routing logic or multiple exportarr processes
3. **Single point of failure** - If the centralized exporter pod fails, all arr-stack metrics are lost
4. **Cross-namespace networking** - Requires network policies and service discovery across namespaces
5. **No clear resource savings** - Running 4 exportarr processes in one pod vs. 4 sidecars has similar overhead

## Implementation Plan (Phase 3: Operational Excellence)

This proposal is **documentation-only** for Phase 2. Implementation is deferred to Phase 3.

### Phase 3 Implementation Steps

1. **Add API keys to cluster.yaml**
   ```yaml
   radarr_api_key: "..."  # sops encrypted
   sonarr_api_key: "..."
   prowlarr_api_key: "..."
   bazarr_api_key: "..."
   ```

2. **Update HelmRelease templates** - Add exportarr sidecar to each arr-stack app:
   - `templates/config/kubernetes/apps/downloads/radarr/app/helmrelease.yaml.j2`
   - `templates/config/kubernetes/apps/downloads/sonarr/app/helmrelease.yaml.j2`
   - `templates/config/kubernetes/apps/downloads/prowlarr/app/helmrelease.yaml.j2`
   - `templates/config/kubernetes/apps/downloads/bazarr/app/helmrelease.yaml.j2`

3. **Create ServiceMonitor templates** - Add Prometheus scrape configs:
   - `templates/config/kubernetes/apps/downloads/radarr/app/servicemonitor.yaml.j2`
   - (repeat for sonarr, prowlarr, bazarr)

4. **Regenerate manifests**
   ```bash
   task configure --yes
   ```

5. **Deploy and verify**
   ```bash
   # Check metrics endpoints
   kubectl -n downloads port-forward svc/radarr 9707:9707
   curl http://localhost:9707/metrics
   
   # Verify Prometheus is scraping
   kubectl -n observability port-forward svc/prometheus 9090:9090
   # Query: up{job="radarr"}
   ```

6. **Create Grafana dashboard** - Build arr-stack dashboard showing:
   - Queue sizes across all apps
   - Disk space trends
   - Indexer success rates (Prowlarr)
   - Download throughput
   - Application health status

### Estimated Resource Impact

Per exportarr sidecar:
- **Memory:** ~50MB (based on Go exporter typical usage)
- **CPU:** ~10m (metrics scraping every 30s)

**Total for 4 apps:**
- Memory: ~200MB
- CPU: ~40m

This is acceptable overhead for the observability value gained.

## Important Notes

### Exportarr Maintenance Status

From the GitHub README:
> "This project is in maintenance mode. Gathering this data from the Sonarr, Radarr etc... APIs is not ideal."

**Implications:**
- Don't expect new features or frequent updates
- Current metrics are stable and sufficient for basic monitoring
- If Exportarr becomes unmaintained, we may need to explore alternatives (e.g., custom exporter)

### Prowlarr Specific Considerations

From Exportarr documentation:
> "Prowlarr collector requires backfill configuration for historical data and can be extremely slow on first requests for long-running instances."

**Mitigation:**
- Set `PROWLARR_BACKFILL: "true"` to enable historical data collection
- Expect slow initial scrape (could take minutes on first Prometheus scrape)
- Consider longer scrape interval for Prowlarr (e.g., 60s instead of 30s)

## Conclusion

**Recommendation:** Implement Exportarr using the **sidecar pattern** in Phase 3.

This provides comprehensive monitoring for our arr-stack applications with minimal operational complexity, following Kubernetes best practices for metrics exporters.

The ~200MB memory overhead is justified by the observability improvements:
- Proactive alerting on queue problems
- Disk space exhaustion prevention
- Indexer performance tracking
- Historical trend analysis

**Next Steps:** Defer implementation to Phase 3: Operational Excellence, after infrastructure monitoring (Phase 2) is complete and stable.
