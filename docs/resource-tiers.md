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
