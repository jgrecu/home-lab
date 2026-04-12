# Installing Talos on HP EliteDesk 800 G3 Mini

## Your Hardware

- 3x HP EliteDesk 800 G3 Mini — Core i5 3.2GHz, 512GB SSD, 16GB RAM
- Plan: 1 controller node + 2 worker nodes

These machines are well-suited for this. The G3 Mini supports UEFI boot, has a standard NVMe/SATA SSD, and Intel NIC — all of which Talos handles natively with no extra drivers needed.

---

## Overview of what you're about to do

```
1. Get a Talos schematic ID for your hardware (factory.talos.dev)
2. Download the Talos ISO
3. Flash it onto a USB drive
4. Configure BIOS on each machine
5. Boot each machine from USB — they enter "maintenance mode"
6. Collect MAC addresses and disk paths from each machine
7. Fill in nodes.yaml
8. Run task bootstrap:talos to push config and bootstrap the cluster
```

---

## Step 1: Get your Schematic ID

Talos uses a concept called a **schematic** — it's a fingerprint that tells the Talos image factory exactly what hardware extensions (drivers, firmware) to bake into your image.

For the HP EliteDesk 800 G3 Mini you almost certainly need **no extra extensions** — the Intel NIC and Intel NVMe/SATA are supported out of the box.

1. Go to https://factory.talos.dev/
2. Leave all extensions unchecked (plain hardware, no GPU/ZFS/special NICs)
3. Click **Generate**
4. You'll get a **Schematic ID** — a long hex string like:
   `ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515`
5. Copy it — you'll put this in `nodes.yaml` for all 3 nodes (same hardware = same schematic)

> If you later need ZFS, special NICs, or GPU passthrough, you regenerate the schematic with those extensions added and upgrade. You don't reinstall from scratch.

---

## Step 2: Download the ISO

From the factory page after generating your schematic, download the **ISO** (not the disk image). It will be named something like:

```
metal-amd64.iso
```

Direct URL pattern (replace SCHEMATIC_ID and VERSION):
```
https://factory.talos.dev/image/SCHEMATIC_ID/v1.9.5/metal-amd64.iso
```

Use the Talos version pinned in this repo (`talenv.yaml` once generated — currently **v1.12.6**).

---

## Step 3: Flash the USB

You only need **one USB drive** — you'll boot all 3 machines from the same USB one at a time.

**On Linux (your Arch machine):**
```bash
# Find your USB device — look for the drive that matches your USB size
lsblk

# Flash it (replace /dev/sdX with your actual USB device — double check this!)
sudo dd if=metal-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Or use a GUI tool like **Balena Etcher** if you prefer.

---

## Step 4: BIOS Settings on each HP EliteDesk 800 G3 Mini

Boot into BIOS by pressing **F10** during startup (HP logo screen).

Make these changes on each machine:

| Setting | Value |
|---|---|
| Secure Boot | **Disabled** |
| Legacy Boot | **Disabled** (keep UEFI only) |
| Fast Boot | **Disabled** |
| USB Boot | **Enabled** |
| Boot Order | USB first, then SSD |
| Virtualization (VT-x) | **Enabled** (needed for some workloads) |
| Wake on LAN | **Enabled** (optional but useful for remote management) |

Save and exit.

> Talos does NOT support Legacy/BIOS boot — UEFI is required. The G3 supports this fine.

---

## Step 5: Boot into Maintenance Mode

Insert the USB, power on the machine. Talos will boot and show a console screen. It does **not** install anything yet — it sits in **maintenance mode** waiting for you to push a config to it.

**Do this for all 3 machines one at a time** (or simultaneously if you have a monitor/switch).

Each machine will show its IP address on the console screen once it gets a DHCP lease. Write these down — you need them for the next step.

> Tip: Reserve these IPs in your router's DHCP settings by MAC address so they don't change. You'll need stable IPs before committing to nodes.yaml.

---

## Step 6: Collect Hardware Details

While each machine is booted into maintenance mode, query it with `talosctl`. The `--insecure` flag is needed because there's no auth set up yet.

**Get the disk path:**
```bash
talosctl get disks -n <machine-ip> --insecure
```

Output looks like:
```
NODE         NAMESPACE   TYPE   ID        VERSION   SIZE      READ ONLY
192.168.1.x  runtime     Disk   sda       1         512 GB    false
192.168.1.x  runtime     Disk   nvme0n1   1         512 GB    false
```

You want the path for the SSD — likely `/dev/sda` or `/dev/nvme0n1`. Use the full path or the serial number (both work in `nodes.yaml`).

**Get the MAC address:**
```bash
talosctl get links -n <machine-ip> --insecure
```

Output looks like:
```
NODE         NAMESPACE   TYPE          ID     VERSION   ALIAS   OPER STATE   HW ADDR
192.168.1.x  network     LinkStatus    eth0   5         eth0    up           aa:bb:cc:dd:ee:ff
```

Grab the `HW ADDR` value for the active ethernet port (`eth0` or `enp*`).

Do this for all 3 machines and record:

| Machine | IP | MAC Address | Disk |
|---|---|---|---|
| controller | 192.168.1.X | aa:bb:cc:... | /dev/nvme0n1 |
| worker-1 | 192.168.1.X | aa:bb:cc:... | /dev/nvme0n1 |
| worker-2 | 192.168.1.X | aa:bb:cc:... | /dev/nvme0n1 |

---

## Step 7: Fill in nodes.yaml

Copy the sample file and fill it in:

```bash
cp nodes.sample.yaml nodes.yaml
```

Edit `nodes.yaml`:

```yaml
nodes:
  - name: "controller"
    address: "192.168.1.10"   # static IP you reserved
    controller: true
    disk: "/dev/nvme0n1"      # from talosctl get disks
    mac_addr: "aa:bb:cc:dd:ee:ff"   # from talosctl get links
    schematic_id: "YOUR_SCHEMATIC_ID_HERE"

  - name: "worker-1"
    address: "192.168.1.11"
    controller: false
    disk: "/dev/nvme0n1"
    mac_addr: "aa:bb:cc:dd:ee:ff"
    schematic_id: "YOUR_SCHEMATIC_ID_HERE"

  - name: "worker-2"
    address: "192.168.1.12"
    controller: false
    disk: "/dev/nvme0n1"
    mac_addr: "aa:bb:cc:dd:ee:ff"
    schematic_id: "YOUR_SCHEMATIC_ID_HERE"
```

> With only 1 controller node, you do **not** have HA control plane (you need 3 controllers for that). For a home lab with 3 machines, 1 controller + 2 workers is the normal trade-off — you get more worker capacity.

---

## Step 8: Fill in cluster.yaml

Copy and fill in the cluster config:

```bash
cp cluster.sample.yaml cluster.yaml
```

Key fields to set:

```yaml
node_cidr: "192.168.1.0/24"       # your home network subnet
cluster_api_addr: "192.168.1.20"  # unused IP — Kubernetes API endpoint
cluster_dns_gateway_addr: "192.168.1.21"  # unused IP — internal DNS
cluster_gateway_addr: "192.168.1.22"      # unused IP — internal ingress
cloudflare_gateway_addr: "192.168.1.23"   # unused IP — external ingress
repository_name: "yourgithub/home-lab"
cloudflare_domain: "yourdomain.com"
cloudflare_token: "your-cf-token"
```

The `cluster_api_addr` and the gateway IPs must be **unused IPs in your subnet** — they are virtual IPs that Cilium will answer for. Do not assign them to any device.

---

## Step 9: Bootstrap the Cluster

Once both YAML files are filled in, run the full bootstrap sequence:

```bash
# Generate all configs from templates
task template:render

# Bootstrap Talos (generates secrets, applies config to nodes, bootstraps k8s)
task bootstrap:talos
```

What this does under the hood:
1. Generates Talos secrets (PKI certs, join tokens) — saved encrypted in `talos/talsecret.sops.yaml`
2. Renders `talconfig.yaml` into per-node config files
3. Pushes config to each node via `talosctl apply --insecure`
4. Nodes wipe their disk, install Talos, reboot
5. `talosctl bootstrap` is called on the controller — Kubernetes starts
6. Downloads `kubeconfig` to your machine

Then bootstrap the apps:
```bash
task bootstrap:apps
```

This installs Cilium, CoreDNS, cert-manager, and Flux. After that, Flux takes over and deploys everything else from Git.

---

## Troubleshooting

**Machine won't boot from USB:**
- Re-check BIOS boot order, make sure Secure Boot is off
- Try re-flashing the USB with `conv=fsync` flag

**No IP shown on Talos console:**
- The machine isn't getting a DHCP lease — check your network cable and switch port
- Try a different cable

**talosctl commands fail with connection refused:**
- Make sure you're using `--insecure` flag during maintenance mode
- Double check the IP shown on the machine's console

**Bootstrap hangs at "waiting for bootstrap":**
- This usually means the controller node can't be reached — verify the IP in `nodes.yaml` matches what the machine got from DHCP
- Check that DHCP reservations are set

**After bootstrap, nodes show NotReady:**
- Normal — Cilium CNI isn't installed yet. Run `task bootstrap:apps` and they'll go Ready within a minute or two.
