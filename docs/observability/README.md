# Homelab Observability & Operations

Complete documentation for the production-ready observability and operational tooling deployed in this Kubernetes homelab.

## Quick Links

- **Status Reports:**
  - [Phase 2: Observability Foundation](./phase2-completion-report.md) - Infrastructure monitoring
  - [Phase 3: Operational Excellence](./phase3-completion-report.md) - Tooling and documentation
  - [Final Status](./final-status.md) - Complete summary
  - [Application Metrics Assessment](./application-metrics-assessment.md) - Immich/Nextcloud/Jellyfin analysis

- **Monitoring Baseline:**
  - [Baseline Before Phase 2](./monitoring-baseline-before.txt) - 44 monitors deployed

## Architecture Overview

### Monitoring Stack

**Prometheus + Grafana**
- 44 ServiceMonitors + PodMonitors
- 100% infrastructure coverage
- 15 Grafana dashboards
- 4 PrometheusRule groups (alerting)

**Loki + fluent-bit**
- Centralized log aggregation
- Log forwarding from all pods
- Grafana integration

**VPA + Goldilocks**
- 67 workloads monitored across 14 namespaces
- Resource optimization recommendations
- Dashboard: https://goldilocks.jgrecu.dev

**Gatus**
- 30+ endpoint health checks
- CloudFlare tunnel monitoring
- Status page: https://gatus.jgrecu.dev

### Operational Tooling

**Task Commands** (`.taskfiles/ops/Taskfile.yaml`)
```bash
task ops:status          # Cluster health dashboard
task ops:logs -- <app>   # Application logs
task ops:pod-errors      # Error detection
task ops:restart -- <app> # Restart application
task ops:describe -- <type> <name> # Resource details
task ops:monitoring      # Prometheus coverage check
```

**Documentation**
- `docs/TROUBLESHOOTING.md` - Common issues and solutions
- `docs/MAINTENANCE.md` - Routine procedures

**CI/CD Validation**
- shellcheck - Script validation
- SOPS validation - Secret encryption
- Pre-commit hooks - Local validation
- flux-local - Flux manifest validation

## Monitoring Coverage

### Infrastructure (100%)

**Storage:**
- Longhorn (replicated block storage)
- SeaweedFS (S3-compatible object storage) - 3 components
- Volsync (backup orchestration)

**Databases:**
- CloudNativePG (PostgreSQL operator)
- Dragonfly (Redis-compatible cache)

**Network:**
- Cilium CNI (agent + operator)
- CoreDNS
- k8s-gateway (external DNS)
- external-dns (CloudFlare)
- Envoy Gateway
- CloudFlare tunnel
- WireGuard VPN

**kube-system:**
- metrics-server
- Reloader (config/secret watcher)
- Spegel (image registry mirror)
- snapshot-controller

**Observability:**
- Prometheus (self-monitoring)
- Alertmanager
- Grafana
- Loki
- fluent-bit
- Gatus
- smartctl-exporter
- kube-state-metrics
- node-exporter

**Flux GitOps:**
- flux-controllers
- flux-operator

**Certificates:**
- cert-manager (controller, cainjector, webhook)

### Applications

**Media Management:**
- Sonarr, Radarr, Prowlarr, Bazarr (with Exportarr sidecars)
- Immich (photo management)

**All other applications** have basic health checks via Gatus.

## Alerting Rules

### Storage
- `LonghornVolumeHighUsage` - Volume >85% full (warning, 5m)
- `LonghornNodeStorageLow` - Node storage >90% full (critical, 5m)

### Certificates
- `CertificateExpiringIn7Days` - Cert expires <7 days (warning, 1h)
- `CertificateNotReady` - Certificate not ready (critical, 10m)

### Flux
- `FluxReconciliationFailure` - Resource failing reconciliation (warning, 10m)

### Backups
- `VolsyncBackupFailure` - Backup out of sync (warning, 1h)

## Dashboards

### Grafana (15 total)

**Kubernetes Infrastructure:**
1. Views / Pods
2. Views / Namespaces
3. Views / Nodes
4. Views / Global
5. System / CoreDNS
6. System / API Server
7. Networking / Cluster
8. Networking / Namespace (Workload)
9. Networking / Namespace (Pods)
10. Networking / Pod
11. Storage / Volumes (Cluster)
12. Storage / Volumes (Namespace)
13. Storage / Volumes (Pod)

**Applications:**
14. CloudNativePG (PostgreSQL)
15. Goldilocks (VPA recommendations)

## Health Checks (Gatus)

### Monitoring Groups

1. **CloudFlare** (8 endpoints)
   - Infrastructure availability
   - API health
   - Tunnel connectivity
   - External service access (Immich, Nextcloud, Forgejo, Kavita)
   - Docker Hub registry
   - Status page

2. **Observability** (1 endpoint)
   - Grafana

3. **Internal Services** (6 endpoints)
   - Homepage, Immich, Nextcloud, Forgejo, Woodpecker CI, Kavita

4. **Downloads** (6 endpoints)
   - Sonarr, Radarr, Prowlarr, Bazarr, Transmission, Autobrr

5. **Entertainment** (2 endpoints)
   - Jellyfin, Seerr

6. **Home Automation** (1 endpoint)
   - Home Assistant

7. **Infrastructure** (5 endpoints)
   - Pi-hole, NFS, Dragonfly, SeaweedFS S3, SeaweedFS master

## Resource Optimization

### VPA (Vertical Pod Autoscaler)

**Status:** Collecting data (started 2026-05-09)  
**Workloads:** 67 across 14 namespaces  
**Mode:** Recommendation-only (no auto-apply)

**Monitored Namespaces:**
- cert-manager, cloud, database-system, downloads, entertainment
- forgejo, home-automation, network, observability, storage
- system-upgrade, volsync-system, woodpecker

**Dashboard:** https://goldilocks.jgrecu.dev

**Timeline:**
- Wait 1-2 weeks for data collection
- Review recommendations in Goldilocks dashboard
- Apply right-sizing to templates
- Regenerate manifests with `task configure --yes`

## CI/CD Validation

### GitHub Actions Workflows

- `shellcheck.yaml` - Shell script validation
- `sops-validate.yaml` - Secret encryption validation
- `flux-local.yaml` - Flux manifest validation
- `e2e.yaml` - End-to-end testing
- `release.yaml` - Release automation
- `label-sync.yaml` - Label management
- `labeler.yaml` - PR labeling

### Pre-commit Hooks

- YAML syntax validation
- Trailing whitespace removal
- End-of-file fixing
- Merge conflict detection
- Large file prevention
- Secret scanning
- Shell script validation
- SOPS encryption validation

## Future Enhancements (Optional)

### Low Priority

**Grafana Alert Notifications**
- Configure Alertmanager routes
- Add Slack/Discord/Email receivers
- Define severity-based routing
- Effort: 1-2 hours

**Application Analytics Dashboards**
- Immich: Requires custom exporter for business metrics
- Nextcloud: Deploy nextcloud-exporter
- Jellyfin: Deploy jellyfin_exporter
- Effort: 2-3 hours per application

### Parked

**NetworkPolicies**
- Network-level security isolation
- Adds operational complexity
- Revisit when needed

## Troubleshooting

See [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) for:
- Pod restart loops and CrashLoopBackOff
- Flux reconciliation failures
- Certificate renewal issues
- Storage and PVC problems
- Network connectivity issues
- Application-specific troubleshooting

## Maintenance

See [MAINTENANCE.md](../MAINTENANCE.md) for:
- Routine maintenance procedures
- Update strategies for Talos/Kubernetes
- Application upgrade procedures
- Backup verification
- Certificate management

## Metrics

**Total Monitors:** 44 ServiceMonitors + PodMonitors  
**Infrastructure Coverage:** 100%  
**Health Checks:** 30+ endpoints  
**Task Commands:** 6 operational commands  
**CI/CD Workflows:** 7 automated validations  
**Documentation:** 5 guides  
**Grafana Dashboards:** 15 dashboards  
**PrometheusRules:** 4 groups (8 alert rules)  

---

**Status:** Production-Ready ✅  
**Last Updated:** 2026-05-09
