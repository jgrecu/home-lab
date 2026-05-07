# 🏠 Home Lab

> Self-hosted Kubernetes homelab on Lenovo ThinkCentre M900, powered by Talos Linux and Flux GitOps

A beginner-friendly homelab project that demonstrates how to run your own Kubernetes cluster for self-hosting applications. Learn GitOps principles, automated deployments, and infrastructure-as-code while building a production-like environment at home.

![Talos](https://img.shields.io/badge/Talos-v1.13.0-blue?logo=talos&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.36.0-blue?logo=kubernetes&logoColor=white)
![Flux](https://img.shields.io/badge/Flux-GitOps-blue?logo=flux&logoColor=white)

## 🚀 What's Running

This homelab runs a collection of self-hosted applications organized by purpose:

**📦 Storage & Backup**
- **SeaweedFS** - S3-compatible object storage
- **Longhorn** - Distributed block storage with snapshots

**📊 Observability**
- **Prometheus** - Metrics collection and alerting
- **Grafana** - Visualization dashboards
- **Loki** - Log aggregation

**🎬 Media**
- **Jellyfin** - Media server
- **Immich** - Photo management and backup
- **Kavita** - eBook and manga reader
- **Seerr** - Media request management
- **Sonarr / Radarr** - TV and movie automation
- **Prowlarr** - Indexer management
- **Bazarr** - Subtitle management
- **Transmission** - Download client
- **Autobrr** - Torrent automation
- **Recyclarr** - Quality profile sync

**🌐 Networking**
- **Cloudflare Tunnel** - Secure external access
- **ExternalDNS** - Automatic DNS management
- **Cilium** - Container networking (CNI - Container Network Interface)
- **cert-manager** - TLS certificate automation

**🔧 System**
- **Flux** - GitOps continuous delivery (CD - Continuous Delivery)
- **Woodpecker CI** - Container-native continuous integration
- **Tuppr** - Automated OS and Kubernetes upgrades
- **Renovate** - Dependency update automation
- **Reloader** - Auto-restart pods on config changes

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
- 📈 [Automated Upgrades (Tuppr)](./docs/tuppr-upgrades.md)
- 🔄 [Disaster Recovery](./docs/disaster-recovery.md)
- 💾 [Volsync Backups](./docs/volsync-deployment-guide.md)

---

## 📝 License

This project is licensed under the MIT License.

**Built with** [cluster-template](https://github.com/onedr0p/cluster-template) by [@onedr0p](https://github.com/onedr0p)
