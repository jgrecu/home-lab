# Application Metrics Assessment

## Overview

Assessment of Prometheus metrics availability for Immich, Nextcloud, and Jellyfin to determine dashboard feasibility.

## Immich

**Metrics Availability:** ✅ Yes (OpenTelemetry)  
**ServiceMonitor:** Already configured  
**Ports:** 8081 (API), 8082 (Microservices)

### Available Metrics

Immich v2.7.5 exposes **performance/operational metrics** via OpenTelemetry:

**Performance Metrics:**
- `immich_*_repository_*_duration` - Repository operation latencies (histograms)
  - Asset repository operations
  - Database operations
  - Storage operations
  - User repository operations
- `immich_job_repository_*_duration` - Background job processing times
- `immich_storage_repository_*_duration` - File I/O operation latencies

**System Metrics:**
- `target_info` - Service metadata (version, runtime)
- Process information (Node.js runtime)

### Missing Business Metrics

Immich does **NOT** expose business/analytics metrics such as:
- ❌ Total photo/video count
- ❌ Storage usage (GB of photos)
- ❌ Upload rate (photos per day)
- ❌ User count
- ❌ Photo views/shares

### Dashboard Feasibility

**✅ Performance Dashboard:** Possible
- API response times
- Repository operation latencies
- Job processing duration
- Database query performance

**❌ Analytics Dashboard:** Not possible
- Would require custom exporter or API scraping
- Immich API (`/api/server/stats`) provides stats but not via Prometheus

### Recommendation

**Create a performance monitoring dashboard** showing:
1. Repository operation P95/P99 latencies
2. Job processing times
3. Storage operation performance
4. Database operation latency

Skip analytics dashboard unless willing to build custom exporter.

## Nextcloud

**Metrics Availability:** ❌ No native Prometheus support  
**ServiceMonitor:** None

### Current State

Nextcloud does not expose Prometheus metrics by default.

### Options

1. **ServerInfo App** - Provides `/ocs/v2.php/apps/serverinfo/api/v1/info`
   - JSON endpoint with server statistics
   - NOT Prometheus format
   - Would require custom exporter

2. **Prometheus Exporter (Community)**
   - https://github.com/xperimental/nextcloud-exporter
   - Standalone Go binary
   - Scrapes Nextcloud API
   - Exposes Prometheus metrics

3. **Custom Exporter**
   - Build sidecar that queries Nextcloud API
   - Convert JSON to Prometheus format

### Recommendation

**Defer Nextcloud dashboard** - Requires additional exporter deployment.

If needed later:
1. Deploy nextcloud-exporter as sidecar
2. Configure with Nextcloud API credentials
3. Add ServiceMonitor
4. Create dashboard

Effort: 2-3 hours (exporter deployment + dashboard creation)

## Jellyfin

**Metrics Availability:** ❌ No native Prometheus support  
**ServiceMonitor:** None

### Current State

Jellyfin does not expose Prometheus metrics by default.

### Options

1. **Jellyfin Exporter Plugin** - Does not exist officially

2. **Community Exporters:**
   - https://github.com/Toyz/jellyfin_exporter
   - Python-based, scrapes Jellyfin API
   - Metrics: library counts, user activity, playback stats

3. **API Scraping**
   - Jellyfin has extensive REST API
   - Could build custom exporter
   - `/System/Info/Public` - Server info
   - `/Items/Counts` - Library statistics
   - `/Users` - User information

### Recommendation

**Defer Jellyfin dashboard** - Requires custom exporter.

If needed later:
1. Deploy jellyfin_exporter (Python) as separate pod
2. Configure with Jellyfin API key
3. Add ServiceMonitor
4. Create dashboard

Effort: 2-3 hours (exporter deployment + dashboard creation)

## Summary

| Application | Native Metrics | Dashboard Type | Status |
|-------------|---------------|----------------|--------|
| Immich | ✅ Yes (OpenTelemetry) | Performance | **Feasible** |
| Nextcloud | ❌ No (needs exporter) | Analytics | **Requires Work** |
| Jellyfin | ❌ No (needs exporter) | Analytics | **Requires Work** |

### Recommendation

**Proceed with Immich performance dashboard only.**

Nextcloud and Jellyfin would each require:
- Deploy community exporter (sidecar or separate pod)
- Configure API credentials
- Add ServiceMonitor
- Create dashboard

Total effort per app: 2-3 hours (exporter deployment + dashboard)

## Next Steps

1. ✅ **Create Immich Performance Dashboard**
   - Repository operation latencies
   - Job processing times
   - Database performance
   - Storage I/O performance

2. **Defer Nextcloud/Jellyfin** unless you want to invest in exporter deployment

Would you like to proceed with:
- A) Just the Immich performance dashboard (feasible now)
- B) Also deploy exporters for Nextcloud/Jellyfin (requires additional work)
- C) Skip all application dashboards (infrastructure monitoring is already complete)

---

## Expected Output

Assessment should produce:

**Metrics Availability**:
- List of applications currently exposing metrics
- Endpoint URLs and ports for each
- Sample metrics showing format and labels

**Coverage Analysis**:
- Percentage of deployed apps with metrics
- Apps lacking metrics endpoints
- Priority recommendations for metrics integration

**Verification**:
```bash
# Test metrics endpoint
curl http://<service>:<port>/metrics
# Expected: Prometheus-format metrics output
```
