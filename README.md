# 🏠 Home Lab

> Self-hosted Kubernetes homelab on Lenovo ThinkCentre M900, powered by Talos Linux and Flux GitOps

A beginner-friendly homelab project that demonstrates how to run your own Kubernetes cluster for self-hosting applications. Learn GitOps principles, automated deployments, and infrastructure-as-code while building a production-like environment at home.

![Talos](https://img.shields.io/badge/Talos-v1.13.0-blue?logo=talos&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.36.0-blue?logo=kubernetes&logoColor=white)
![Flux](https://img.shields.io/badge/Flux-GitOps-blue?logo=flux&logoColor=white)

## 🚀 What's Running

This homelab runs a collection of self-hosted applications organized by purpose:

**📦 Storage & Backup**
- **SeaweedFS** - S3-compatible distributed object storage
- **Longhorn** - Distributed block storage with replication and snapshots
- **VolSync** - Automated daily PVC volume backup/replication via Restic to SeaweedFS S3
- **CSI Driver NFS** - Network File System (NFS) storage driver integration
- **S3Manager** - Web-based S3 bucket management interface for SeaweedFS

**📊 Observability**
- **Kube-Prometheus-Stack** - Complete Prometheus and Alertmanager stack for cluster metrics scraping and alerting
- **Grafana** - Advanced visualization and infrastructure monitoring dashboards
- **Loki** - Scalable log aggregation and indexing
- **Fluent Bit** - Lightweight log processor and forwarder
- **Gatus** - Service health monitoring and interactive status dashboard (30+ endpoints)
- **Goldilocks** - Resource recommendation utility for pod CPU/Memory optimization
- **Smartctl Exporter** - Hardware monitoring and SMART status metrics collection

**🎬 Media & Entertainment**
- **Jellyfin** - Open-source media server with hardware transcoding support
- **Immich** - Self-hosted backup and management platform for photos and videos
- **Kavita** - Feature-rich eBook, comic, and manga reader
- **Seerr** - Interactive request management platform for media files
- **Sonarr / Radarr** - Automated TV show and movie download organizers
- **Prowlarr** - Centralized indexer manager for torrent trackers and Usenet
- **Bazarr** - Automatic subtitle companion for Sonarr and Radarr
- **Transmission** - Lightweight, high-performance BitTorrent client
- **Autobrr** - High-speed automated torrent monitor and downloader
- **Recyclarr** - Automated Sonarr/Radarr quality profile and custom format sync
- **FlareSolverr** - Cloudflare bypass proxy for torrent indexers

**🌐 Networking**
- **Cloudflare Tunnel** - Secure, credential-managed external network access without opening router ports
- **ExternalDNS (Cloudflare DNS)** - Automatic sync of internal/external gateway records with Cloudflare DNS
- **Cilium** - High-performance eBPF-based container networking (CNI) with Direct Server Return (DSR) load balancing
- **cert-manager** - Automated TLS certificate generation using Let's Encrypt and Cloudflare ACME validation
- **Pi-hole** - Network-wide ad blocking and custom split-horizon local DNS resolution
- **WireGuard (wg-easy)** - Self-hosted VPN access with a sleek web administration dashboard
- **Envoy Gateway** - Modern Kubernetes Gateway API ingress controller and routing engine

**💼 Productivity & Collaboration**
- **Nextcloud** - Complete self-hosted productivity hub for cloud storage, documents, and contacts
- **Forgejo** - Lightweight, self-hosted software development platform and Git service

**🏠 Home Automation**
- **Home Assistant** - Smart home automation engine and hub for local device control

**🔧 System & GitOps**
- **Flux CD** - GitOps continuous delivery engine syncing cluster state directly from Git
- **Woodpecker CI** - Container-native, Kubernetes-executor continuous integration engine
- **Tuppr** - Automated Talos Linux OS and Kubernetes cluster upgrades with node health checks
- **Renovate** - Automated dependency tracking and pull request creation
- **Reloader** - Hot-reloads application pods automatically when ConfigMaps or Secrets change
- **Spegel** - Stateless cluster-local OCI registry mirror and container image cache
- **Vertical Pod Autoscaler (VPA)** - Automatic pod resource allocation and scaling recommendation

[View full app inventory →](./kubernetes/apps/)

## 🏗️ Quick Start

### Prerequisites

**Hardware:**
- 2+ nodes (e.g., Lenovo ThinkCentre M900: Core i5 2.5GHz, 512GB SSD, 16GB RAM)
- Network: Static IP addresses, router access
- Storage: SSD or NVMe drives recommended

**Accounts:**
- GitHub account
- Cloudflare account with a domain

**Tools** (installed via `mise`):
- `talosctl` - Talos Linux management
- `kubectl` - Kubernetes CLI
- `task` - Task runner
- `age` - Encryption for secrets (SOPS - Secrets OPerationS)

### Installation Steps

**1. Clone and configure**

```sh
# Clone this repository
git clone https://github.com/yourusername/home-lab.git
cd home-lab

# Install mise (tool version manager)
curl https://mise.run | sh
mise trust
mise install

# Generate configuration files
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

This generates Kubernetes and Talos configuration from templates using your settings.

**4. Bootstrap Talos cluster**

```sh
# Flash Talos to your nodes
# Then install Talos
task bootstrap:talos

# Commit generated secrets
git add -A
git commit -m "chore: add encrypted secrets"
git push
```

**5. Install applications**

```sh
# Deploy Cilium, Flux, and sync all apps
task bootstrap:apps

# Watch deployments roll out
kubectl get pods --all-namespaces --watch
```

**6. Verify installation**

```sh
# Check Flux sync status
flux check
flux get ks -A

# Check app deployments
kubectl get pods -A
```

## 💡 Why This Project?

**Template-Driven Configuration**
- Change settings in one place (`cluster.yaml`)
- Regenerate all configs with `task configure`
- Never manually edit generated files

**Encrypted Secrets**
- All secrets encrypted with SOPS (age encryption)
- Safe to commit to public GitHub
- Flux decrypts automatically in-cluster

**Automated Upgrades**
- Tuppr handles Talos and Kubernetes upgrades safely
- Health checks between nodes prevent cascading failures
- Maintenance windows (Sundays 02:00 UTC)

**Learning Platform**
- Hands-on experience with GitOps (Flux - automated deployments from git)
- Real Kubernetes operations (kubectl, manifests, debugging)
- Self-hosting applications (media, monitoring, storage)

## 📖 Learn More

- 📚 [Full Documentation](./docs/README.md)
- 🛠️ [Troubleshooting Guide](./docs/TROUBLESHOOTING.md) - Symptom-driven diagnostics
- 🧹 [Maintenance Procedures](./docs/MAINTENANCE.md) - Routine operation checklists
- 📈 [Automated Upgrades (Tuppr)](./docs/tuppr-upgrades.md)
- 🔄 [Disaster Recovery](./docs/disaster-recovery.md)
- 💾 [Volsync Backups](./docs/volsync-deployment-guide.md)
- 📦 [Pod Security Standards](./docs/pod-security-standards.md) - Security enforcement policies

## 🔧 Operational Commands

### Cluster Status

```bash
# Overall cluster health
task ops:status

# Failed pods
task ops:pod-errors

# Monitoring coverage
task ops:monitoring-status
```

### Application Management

```bash
# View application logs
task ops:logs -- <app-name> [namespace]

# Restart application
task ops:restart -- <app-name> [namespace]

# Describe resource
task ops:describe -- <type> <name> [namespace]
```

### Storage Management

```bash
# Bootstrap SeaweedFS S3 storage buckets and keys
task storage:bootstrap-seaweedfs

# Backup status
task storage:backup-status

# PVC usage
task storage:pvc-usage

# Longhorn status
task storage:longhorn-status

# Restore PVC from backup
task storage:restore-pvc -- <namespace> <pvc-name> <capacity>
```

### Troubleshooting

See comprehensive guides:
- [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) - Common issues and solutions
- [MAINTENANCE.md](docs/MAINTENANCE.md) - Regular maintenance procedures
- [Disaster Recovery](docs/disaster-recovery.md) - Recovery procedures

---

## 📝 License

This project is licensed under the MIT License.

**Built with** [cluster-template](https://github.com/onedr0p/cluster-template) by [@onedr0p](https://github.com/onedr0p)
