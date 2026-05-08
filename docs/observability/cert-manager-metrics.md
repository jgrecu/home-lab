# cert-manager Metrics

## Overview

cert-manager exposes Prometheus metrics for monitoring certificate lifecycle, ACME challenges, controller performance, and issuer health.

## ServiceMonitor Configuration

- **Namespace:** cert-manager
- **Interval:** 60s
- **Port:** http-metrics (9402)
- **Scrape Timeout:** 30s
- **Components Monitored:**
  - cert-manager controller
  - cainjector
  - webhook

## Key Metrics

### Certificate Lifecycle

- `certmanager_certificate_expiration_timestamp_seconds` - Unix timestamp when certificate expires
- `certmanager_certificate_not_after_timestamp_seconds` - Certificate validity end time
- `certmanager_certificate_not_before_timestamp_seconds` - Certificate validity start time
- `certmanager_certificate_renewal_timestamp_seconds` - Last renewal timestamp
- `certmanager_certificate_ready_status` - Certificate ready status (0=not ready, 1=ready)

### ACME Challenge Metrics

- `certmanager_certificate_challenge_status` - Current status of certificate challenges
- `certmanager_http_acme_client_request_count` - Total count of ACME HTTP-01 challenge requests
- `certmanager_http_acme_client_request_duration_seconds` - ACME request latency histogram
- `certmanager_http_acme_client_request_duration_seconds_count` - Count of ACME requests
- `certmanager_http_acme_client_request_duration_seconds_sum` - Sum of ACME request durations

### Controller Performance

- `certmanager_controller_sync_call_count` - Number of controller reconciliation loops executed
- `certmanager_controller_sync_error_count` - Number of controller reconciliation errors

### Issuer Health

- `certmanager_clusterissuer_ready_status` - ClusterIssuer ready status (0=not ready, 1=ready)

### System Metrics

- `certmanager_clock_time_seconds` - Current clock time (counter)
- `certmanager_clock_time_seconds_gauge` - Current clock time (gauge)

## Verification

Check that Prometheus is scraping cert-manager metrics:

```bash
# Port-forward to Prometheus
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090

# Query cert-manager targets (should show 1 target in UP state)
curl -s http://localhost:9090/api/v1/targets | \
  jq '.data.activeTargets[] | select(.labels.job | contains("cert-manager")) | {job: .labels.job, health: .health}'

# Sample a certificate expiration metric
curl -s 'http://localhost:9090/api/v1/query?query=certmanager_certificate_expiration_timestamp_seconds' | \
  jq '.data.result[] | {name: .metric.name, namespace: .metric.namespace, expiration: .value[1]}'
```

## Useful PromQL Queries

### Certificates Expiring Soon

```promql
# Certificates expiring in less than 30 days
(certmanager_certificate_expiration_timestamp_seconds - time()) / 86400 < 30
```

### Certificate Status

```promql
# Non-ready certificates
certmanager_certificate_ready_status == 0
```

### Controller Errors

```promql
# Rate of controller sync errors over 5 minutes
rate(certmanager_controller_sync_error_count[5m])
```

### ACME Challenge Success Rate

```promql
# ACME request success rate (non-error responses)
sum(rate(certmanager_http_acme_client_request_count{status!~"5.."}[5m])) /
sum(rate(certmanager_http_acme_client_request_count[5m]))
```

## Grafana Dashboard

Import the official cert-manager dashboard:

- **Dashboard ID:** 11001
- **Source:** https://grafana.com/grafana/dashboards/11001

Alternative: Create custom dashboard with panels for:
- Certificate expiration timeline
- Certificate ready status
- Controller sync error rate
- ACME challenge success rate
- Issuer health status

## Alerting Recommendations

Configure alerts for:

1. **Certificate Expiration Warning** - Alert when certificates expire in < 21 days
2. **Certificate Not Ready** - Alert when certificate ready status = 0 for > 5 minutes
3. **Controller Errors** - Alert on sustained sync error rate
4. **ACME Challenge Failures** - Alert on high ACME failure rate
5. **Issuer Not Ready** - Alert when ClusterIssuer ready status = 0

## References

- [cert-manager Monitoring Guide](https://cert-manager.io/docs/monitoring/)
- [cert-manager Prometheus Metrics](https://cert-manager.io/docs/monitoring/prometheus-metrics/)
