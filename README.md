# 🏠 Home Lab

> Self-hosted Kubernetes homelab on Lenovo ThinkCentre M900, powered by Talos Linux and Argo CD GitOps

A home lab project demonstrating production-grade self-hosting: GitOps continuous delivery, automated secret management, PVC backups, and infrastructure-as-code — running on commodity hardware.

![Talos](https://img.shields.io/badge/Talos-v1.14.5-blue?logo=talos&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.37.2-blue?logo=kubernetes&logoColor=white)
![Argo CD](https://img.shields.io/badge/Argo%20CD-v10.17.2-orange?logo=argo&logoColor=white)

## 🚀 What's Running

| Category | Applications |
|----------|-------------|
| **Storage & Backup** | SeaweedFS, Longhorn, VolSync, CSI Driver NFS, S3Manager |
| **Observability** | Kube-Prometheus-Stack, Grafana, Loki, Fluent Bit, Gatus, Goldilocks, Smartctl Exporter |
| **Media & Entertainment** | Jellyfin, Immich, Kavita |
| **Networking** | Cloudflare Tunnel, ExternalDNS, Cilium, cert-manager, Pi-hole, WireGuard, Envoy Gateway |
| **Productivity** | Nextcloud, Forgejo |
| **Home Automation** | Home Assistant |
| **System & GitOps** | Argo CD, Woodpecker CI, Tuppr, Renovate, Reloader, Spegel, VPA |

[View full app inventory →](./kubernetes/apps/)

## 🏗️ Quick Start

### Prerequisites

**Hardware:**
- 2+ nodes (e.g., Lenovo ThinkCentre M900: Core i5 2.5GHz, 512GB SSD, 16GB RAM)
- Static IP addresses, router access

**Accounts:**
- GitHub account
- Cloudflare account with a domain
- AWS account (KMS key for Vault auto-unseal)

**Tools** (installed via `mise`):
- `talosctl` — Talos Linux management
- `kubectl` — Kubernetes CLI
- `just` — Task runner
- `sops` / `age` — Secret encryption (bootstrap only)

### Installation

**1. Clone and install tools**

```sh
git clone https://github.com/yourusername/home-lab.git
cd home-lab
curl https://mise.run | sh && mise trust && mise install
```

**2. Bootstrap Talos cluster**

```sh
just bootstrap bootstrap-talos
```

**3. Install core infrastructure (Argo CD + Vault + ESO)**

```sh
just bootstrap bootstrap-apps
```

**4. Customize your cluster**

Edit manifests directly in `kubernetes/apps/` and `kubernetes/argo/apps/`:
- Add/remove applications
- Adjust resources and configurations
- Secrets go in Vault; reference them with `ExternalSecret` manifests

**5. Push and let Argo CD sync**

```sh
git add -A && git commit -m "feat: my changes" && git push
kubectl -n argo-system get applications
```

## 💡 Why This Project?

**GitOps with Argo CD** — Every change is a git commit. Argo CD continuously reconciles the cluster to match `kubernetes/`. No manual `kubectl apply`.

**Production-grade secrets (Vault + ESO)** — Credentials live in HashiCorp Vault, synced to Kubernetes by External Secrets Operator. The repo contains only one SOPS-encrypted file (`vault-kms.sops.yaml` — AWS KMS credentials to unseal Vault on startup). Everything else is plain YAML.

**Automated Upgrades** — Tuppr handles Talos and Kubernetes upgrades safely with health checks between nodes. Renovate keeps all Helm charts and container images up to date automatically.

**Reliable Backups** — VolSync backs up every PVC to both SeaweedFS (local) and Cloudflare R2 (offsite) via restic. Backup secrets are stored in Vault.

## 📖 Documentation

- [Full Documentation](./docs/README.md)
- [Secret Management (Vault, ESO)](./docs/SECRET_MANAGEMENT.md)
- [Disaster Recovery](./docs/disaster-recovery.md)
- [Troubleshooting Guide](./docs/TROUBLESHOOTING.md)
- [Maintenance Procedures](./docs/MAINTENANCE.md)
- [Automated Upgrades (Tuppr)](./docs/tuppr-upgrades.md)
- [Volsync Backups](./docs/volsync-deployment-guide.md)
- [Pod Security Standards](./docs/pod-security-standards.md)
- [Resource Tiers](./docs/resource-tiers.md)

## 🔧 Quick Commands

```bash
# Cluster status
just ops status
just ops pod-errors
just ops monitoring-status

# Application management
just ops logs <app-name> [namespace]
just ops restart <app-name> [namespace]
just ops describe <type> <name> [namespace]

# Storage & Backup
just ops backup-status
just ops pvc-usage
just ops longhorn-status
just ops restore-pvc <namespace> <pvc-name> <capacity>

# Validate Argo CD rendering
./scripts/argo-parity.sh --render-only --skip-app vault
```

---

## 📝 License

MIT License.
