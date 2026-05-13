# Resource Tier System

## Overview

All homelab apps are categorized into three resource tiers based on criticality and resource needs.

## Tier 1: System-Critical Infrastructure

**Apps:** cilium, coredns, metrics-server, reloader, spegel, snapshot-controller, cert-manager, flux-operator, flux-instance, envoy-gateway, cloudflare-dns, k8s-gateway

**Resources:**
- CPU request: 50m-200m
- CPU limit: 200m-1000m (prevents runaway processes)
- Memory request: 64Mi-256Mi
- Memory limit: 128Mi-1Gi

**Why:** Must be scheduled reliably, cannot consume all node resources.

## Tier 2: Standard Applications

**Apps:** All downloads (*arr stack), entertainment (most apps), observability (grafana, gatus, fluent-bit), forgejo, woodpecker, nextcloud, homepage

**Resources:**
- CPU request: 10m-50m
- CPU limit: NONE (allows bursting)
- Memory request: 128Mi-256Mi
- Memory limit: 512Mi-2Gi

**Why:** Minimal guaranteed CPU for scheduling, can burst freely during load spikes.

## Tier 3: Heavy Workloads

**Apps:** Postgres clusters, dragonfly cache, immich, prometheus, loki, longhorn, seaweedfs

**Resources:**
- CPU request: 100m-1000m
- CPU limit: NONE (allows bursting)
- Memory request: 512Mi-4Gi
- Memory limit: 2Gi-8Gi

**Why:** Higher guarantees for intensive workloads, free to burst as needed.

## QoS Classes

- **Guaranteed:** requests == limits for both CPU and memory
- **Burstable:** requests < limits OR only requests specified
- **BestEffort:** No requests or limits specified

**Target:** All apps Burstable or Guaranteed (no BestEffort).

## Scheduling Policies

Beyond resource requests/limits, critical multi-replica services use scheduling policies for high availability.

### Topology Spread Constraints

**CoreDNS** (2 replicas) uses `topologySpreadConstraints` to distribute replicas across nodes:
```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
```

This ensures DNS replicas are spread evenly, though both currently run on m900-ctrl due to control-plane nodeAffinity requirements.

### Pod Anti-Affinity

**Envoy Gateway** (2 replicas per gateway) uses soft pod anti-affinity to prevent co-location:
```yaml
podAntiAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
```

**Why soft (preferred) instead of hard (required)?**
- With 4 gateway pods (2 external + 2 internal) across 3 nodes, hard anti-affinity blocks rolling updates
- Soft anti-affinity achieves the same distribution goal while allowing scheduler flexibility during deployments
- Weight of 100 strongly prefers spreading without making it impossible

**Current distribution:**
- envoy-external: m900-ctrl + m920x-wrk2
- envoy-internal: m900-ctrl + m920x-wrk2

This ensures ingress availability if any single node fails.

---

## Usage

This document serves as a reference for resource allocation decisions. When adding new applications:

1. Determine tier based on criticality and resource needs
2. Apply appropriate requests/limits from the tier guidelines
3. For multi-replica apps, consider scheduling policies (topology spread, anti-affinity)
4. Verify pod placement with `kubectl get pods -A -o wide`
