# Pi-hole Conditional DNS Forwarding

## The Problem Pi-hole Creates

Once you point your router's DNS at Pi-hole, **all** DNS queries from your home network go through Pi-hole. That includes `*.yourdomain.com` — the domains your cluster services use.

Pi-hole doesn't know about your cluster, so it would either block or fail to resolve `homepage.yourdomain.com`, `pihole.yourdomain.com`, etc.

You need to tell Pi-hole: *"for anything ending in `yourdomain.com`, ask the cluster's DNS gateway instead of going to the internet."*

That's `cluster_dns_gateway_addr` — the IP you set in `cluster.yaml`. It's the k8s_gateway service that knows about all your cluster's routes.

---

## Where to Configure It

**Pi-hole v5:** Settings → DNS → scroll to bottom → Conditional Forwarding section

**Pi-hole v6:** Settings → DNS → Upstream DNS tab → Conditional Forwarding section

---

## What to Enter

| Field | Value |
|---|---|
| Local network in CIDR notation | `192.168.1.0/24` *(your node_cidr)* |
| IP address of your DHCP server (router) | `192.168.1.1` *(your router IP)* |
| Local domain name | `yourdomain.com` |

**What this does:** Any query for `*.yourdomain.com` gets forwarded to `cluster_dns_gateway_addr` (k8s_gateway), which resolves it to the correct Envoy Gateway IP inside the cluster.

---

## The Full DNS Flow After Setup

```
Your laptop types: https://homepage.yourdomain.com
         |
         ▼
Pi-hole receives DNS query for "homepage.yourdomain.com"
         |
         | (matches conditional forwarder for yourdomain.com)
         ▼
k8s_gateway (cluster_dns_gateway_addr — e.g. 192.168.1.21)
         |
         | (knows this hostname maps to Envoy internal gateway)
         ▼
Returns IP: cluster_gateway_addr (e.g. 192.168.1.22) — Envoy internal
         |
         ▼
Your browser connects to Envoy Gateway
         |
         ▼
Homepage pod
```

For any normal domain (`google.com`, `github.com`), Pi-hole handles it itself — blocks ads, forwards clean queries to `1.1.1.1`.

---

## Step-by-Step in the UI

1. Go to `https://pihole.yourdomain.com/admin`
2. Login with your `pihole_admin_password`
3. **Settings → DNS**
4. Scroll to **Conditional Forwarding** at the bottom
5. Check **"Use Conditional Forwarding"**
6. Fill in:
   - Local network: `192.168.1.0/24`
   - Router (DHCP server) IP: your router's IP (usually `.1`)
   - Domain: `yourdomain.com`
7. Save

---

## One Thing to Be Aware Of

Pi-hole's conditional forwarding sends the query to `cluster_dns_gateway_addr`. This is a private RFC1918 address — private IPs are never on Pi-hole's block lists so this is safe by default.
