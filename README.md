# 🏠 Home Lab

> Self-hosted Kubernetes homelab on Lenovo ThinkCentre M900, powered by Talos Linux and Flux GitOps

A beginner-friendly homelab project demonstrating how to run your own Kubernetes cluster for self-hosting applications. Learn GitOps principles, automated deployments, and infrastructure-as-code while building a production-like environment at home.

![Talos](https://img.shields.io/badge/Talos-v1.13.0-blue?logo=talos&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.36.0-blue?logo=kubernetes&logoColor=white)
![Flux](https://img.shields.io/badge/Flux-GitOps-blue?logo=flux&logoColor=white)

## 🚀 What's Running

| Category | Applications |
|----------|-------------|
| **Storage & Backup** | SeaweedFS, Longhorn, VolSync, CSI Driver NFS, S3Manager |
| **Observability** | Kube-Prometheus-Stack, Grafana, Loki, Fluent Bit, Gatus, Goldilocks, Smartctl Exporter |
| **Media & Entertainment** | Jellyfin, Immich, Kavita |
| **Networking** | Cloudflare Tunnel, ExternalDNS, Cilium, cert-manager, Pi-hole, WireGuard, Envoy Gateway |
| **Productivity** | Nextcloud, Forgejo |
| **Home Automation** | Home Assistant |
| **System & GitOps** | Flux CD, Woodpecker CI, Tuppr, Renovate, Reloader, Spegel, VPA |

[View full app inventory →](./kubernetes/apps/)

## 🏗️ Quick Start

### Prerequisites

**Hardware:**
- 2+ nodes (e.g., Lenovo ThinkCentre M900: Core i5 2.5GHz, 512GB SSD, 16GB RAM)
- Static IP addresses, router access
- SSD or NVMe drives recommended

**Accounts:**
- GitHub account
- Cloudflare account with a domain

**Tools** (installed via `mise`):
- `talosctl` - Talos Linux management
- `kubectl` - Kubernetes CLI
- `task` - Task runner
- `age` - Encryption for secrets (SOPS)

### Installation

**1. Clone and configure**

```sh
git clone https://github.com/yourusername/home-lab.git
cd home-lab

curl https://mise.run | sh
mise trust
mise install

task init
```

**2. Configure your cluster**

Edit `cluster.yaml` and `nodes.yaml` with your:
- Node IP addresses and hostnames
- Cloudflare domain and tunnel credentials
- Network settings (gateway, DNS servers)

**3. Generate manifests**

```sh
task configure --yes
```

Generates Kubernetes and Talos configuration from templates.

**4. Bootstrap Talos cluster**

```sh
task bootstrap:talos

git add -A
git commit -m "chore: add encrypted secrets"
git push
```

**5. Install applications**

```sh
task bootstrap:apps

kubectl get pods --all-namespaces --watch
```

**6. Verify installation**

```sh
flux check
flux get ks -A
kubectl get pods -A
```

## 💡 Why This Project?

**Template-Driven Configuration** - Change settings in `cluster.yaml`, regenerate all configs with `task configure`. Never manually edit generated files.

**Encrypted Secrets** - All secrets encrypted with SOPS (age encryption). Safe to commit to public GitHub. Flux decrypts automatically in-cluster.

**Automated Upgrades** - Tuppr handles Talos and Kubernetes upgrades safely with health checks between nodes. Maintenance windows: Sundays 02:00 UTC.

**Learning Platform** - Hands-on GitOps (Flux), real Kubernetes operations (kubectl, manifests, debugging), and self-hosting applications (media, monitoring, storage).

## 📖 Documentation

- [Full Documentation](./docs/README.md)
- [Troubleshooting Guide](./docs/TROUBLESHOOTING.md) - Symptom-driven diagnostics
- [Maintenance Procedures](./docs/MAINTENANCE.md) - Routine operation checklists
- [Automated Upgrades (Tuppr)](./docs/tuppr-upgrades.md)
- [Disaster Recovery](./docs/disaster-recovery.md)
- [Volsync Backups](./docs/volsync-deployment-guide.md)
- [Pod Security Standards](./docs/pod-security-standards.md)

## 🔧 Quick Commands

```bash
# Cluster status
task ops:status
task ops:pod-errors
task ops:monitoring-status

# Application management
task ops:logs -- <app-name> [namespace]
task ops:restart -- <app-name> [namespace]
task ops:describe -- <type> <name> [namespace]

# Storage
task storage:backup-status
task storage:pvc-usage
task storage:longhorn-status
task storage:restore-pvc -- <namespace> <pvc-name> <capacity>
```

---

## 📝 License

MIT License. Built with [cluster-template](https://github.com/onedr0p/cluster-template) by [@onedr0p](https://github.com/onedr0p).
