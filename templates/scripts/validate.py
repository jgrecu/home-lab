#!/usr/bin/env python3
"""
Validate cluster.toml against the Pydantic schema.

Usage:
  validate.py cluster.toml     -- validate and exit 0 on success, 1 on failure
  validate.py --schema         -- print the JSON Schema to stdout
"""
from __future__ import annotations

import sys
import json
import argparse
import tomllib
from pathlib import Path
from typing import List, Optional

from pydantic import BaseModel, Field


class NodeConfig(BaseModel):
    name: str = Field(description="Node hostname (lowercase, alphanumeric, hyphens)")
    address: str = Field(description="Static IP address (must be within node_cidr)")
    controller: bool = Field(description="True if this is a control-plane node")
    disk: str = Field(description="Disk path (/dev/...) or serial number for disk selection")
    mac_addr: str = Field(description="Primary NIC MAC address for network interface selection")
    schematic_id: str = Field(description="Talos factory schematic ID from factory.talos.dev")
    mtu: Optional[int] = Field(default=1500, description="NIC MTU (default: 1500)")
    secureboot: Optional[bool] = Field(default=False, description="Enable SecureBoot on UEFI platforms")
    encrypt_disk: Optional[bool] = Field(default=False, description="Enable TPM-based disk encryption")
    kernel_modules: Optional[List[str]] = Field(default_factory=list, description="Extra kernel modules")
    media_node: Optional[bool] = Field(default=False, description="Label for downloads/media workloads")


class ClusterConfig(BaseModel):
    # ── Network ──────────────────────────────────────────────────────────────
    node_cidr: str = Field(description="Node network CIDR (e.g. 192.168.1.0/24)")
    node_dns_servers: Optional[List[str]] = Field(default=None, description="DNS servers (default: Cloudflare)")
    node_ntp_servers: Optional[List[str]] = Field(default=None, description="NTP servers (default: Cloudflare)")
    node_default_gateway: Optional[str] = Field(default=None, description="Default gateway (default: first IP of node_cidr)")
    node_vlan_tag: Optional[str] = Field(default=None, description="VLAN tag for Talos nodes")

    # ── Cluster addresses ────────────────────────────────────────────────────
    cluster_api_addr: str = Field(description="Kubernetes API VIP (unused IP within node_cidr)")
    cluster_api_tls_sans: Optional[List[str]] = Field(default=None, description="Additional API server cert SANs")
    cluster_pod_cidr: Optional[str] = Field(default="10.42.0.0/16", description="Pod CIDR (must not overlap node_cidr)")
    cluster_svc_cidr: Optional[str] = Field(default="10.43.0.0/16", description="Service CIDR (must not overlap node_cidr)")
    cluster_dns_gateway_addr: str = Field(description="Load balancer IP for k8s-gateway (split-DNS)")
    cluster_gateway_addr: str = Field(description="Load balancer IP for internal Envoy gateway")
    transmission_peer_addr: str = Field(description="Load balancer IP for Transmission peer port")
    wg_easy_vpn_addr: str = Field(description="Load balancer IP for WireGuard Easy VPN")
    wg_easy_admin_password: str = Field(description="WireGuard Easy admin password")
    wg_easy_external_host: str = Field(description="External hostname for WireGuard clients")
    wg_easy_server_private_key: str = Field(description="WireGuard server private key (for migration)")
    pihole_dns_addr: str = Field(description="Load balancer IP for Pi-hole")
    pihole_admin_password: str = Field(description="Pi-hole admin dashboard password")
    cloudflare_gateway_addr: str = Field(description="Load balancer IP for Cloudflare Tunnel gateway")

    # ── Cloudflare ───────────────────────────────────────────────────────────
    cloudflare_domain: str = Field(description="Cloudflare domain (e.g. example.com)")
    cloudflare_token: str = Field(description="Cloudflare API token (Zone:DNS:Edit + Tunnel:Read)")

    # ── Cilium ───────────────────────────────────────────────────────────────
    cilium_loadbalancer_mode: Optional[str] = Field(default="dsr", description="'dsr' or 'snat'")
    cilium_bgp_router_addr: Optional[str] = Field(default=None)
    cilium_bgp_router_asn: Optional[str] = Field(default=None)
    cilium_bgp_node_asn: Optional[str] = Field(default=None)

    # ── Repository ───────────────────────────────────────────────────────────
    repository_name: str = Field(description="GitHub repository (owner/name)")
    repository_branch: Optional[str] = Field(default="main")
    repository_visibility: Optional[str] = Field(default="public")
    grafana_admin_password: str

    # ── NFS ──────────────────────────────────────────────────────────────────
    nfs_server_addr: str
    nfs_server_path: str
    nfs_media_path: str
    nfs_photos_path: str
    nfs_books_path: str
    nfs_seaweedfs_path: str
    nfs_nextcloud_path: str
    nextcloud_admin_password: str

    # ── Forgejo ──────────────────────────────────────────────────────────────
    forgejo_admin_email: str
    forgejo_admin_password: str
    forgejo_runner_secret: str

    # ── Linkding ─────────────────────────────────────────────────────────────
    linkding_admin_password: str
    linkding_healthcheck_token: str

    # ── Woodpecker CI ────────────────────────────────────────────────────────
    woodpecker_admin_user: str
    woodpecker_oauth_client_id: str
    woodpecker_oauth_client_secret: str
    woodpecker_agent_secret: str

    # ── Media stack ──────────────────────────────────────────────────────────
    radarr_api_key: str
    recyclarr_radarr_api_key: str
    sonarr_api_key: str
    recyclarr_sonarr_api_key: str
    prowlarr_api_key: str
    bazarr_api_key: str
    sabnzbd_api_key: str

    # ── Grimmory ─────────────────────────────────────────────────────────────
    grimmory_mariadb_root_password: str
    grimmory_mariadb_password: str

    # ── Health Auto Export ───────────────────────────────────────────────────
    hae_mongo_password: str
    hae_read_token: str
    hae_write_token: str

    # ── Volsync ──────────────────────────────────────────────────────────────
    volsync_restic_password: str
    volsync_s3_access_key: str
    volsync_s3_secret_key: str

    # ── SeaweedFS ────────────────────────────────────────────────────────────
    seaweedfs_s3_access_key_id: str
    seaweedfs_s3_secret_access_key: str

    # ── Cloudflare R2 offsite backup ─────────────────────────────────────────
    r2_access_key_id: str
    r2_secret_access_key: str
    r2_endpoint: str
    r2_bucket: str

    # ── Nodes ────────────────────────────────────────────────────────────────
    nodes: List[NodeConfig] = Field(description="Cluster node definitions (at least one controller required)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("config", nargs="?", default="cluster.toml", help="Path to cluster.toml")
    parser.add_argument("--schema", action="store_true", help="Print JSON Schema to stdout and exit")
    args = parser.parse_args()

    if args.schema:
        schema = ClusterConfig.model_json_schema()
        schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
        schema["title"] = "cluster.toml — homelab cluster configuration"
        print(json.dumps(schema, indent=2))
        return

    config_path = Path(args.config)
    if not config_path.exists():
        print(f"✗ {config_path} not found — run 'just init' first", file=sys.stderr)
        sys.exit(1)

    try:
        from pydantic import ValidationError
        with open(config_path, "rb") as f:
            data = tomllib.load(f)
        ClusterConfig(**data)
        print(f"✓ {config_path} is valid")
    except ValidationError as e:
        print(f"✗ {config_path} has validation errors:", file=sys.stderr)
        for err in e.errors():
            loc = " → ".join(str(x) for x in err["loc"])
            print(f"  {loc}: {err['msg']}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"✗ {config_path}: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
