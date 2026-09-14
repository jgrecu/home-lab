# external-dns v1.22.0+ Compatibility Issue

## Issue Summary

external-dns v1.22.0 introduces a **breaking change** for clusters using:
- Gateway API (HTTPRoute) as the source
- Cloudflare as the DNS provider with `--cloudflare-proxied` enabled
- Private IP addresses for Gateway LoadBalancer (e.g., 192.168.1.168)
- Cloudflare Tunnel for external access

## What Broke

### Before (v1.21.1 - Working)
- external-dns created **CNAME records** pointing to Cloudflare Tunnel
- Example: `forgejo.jgrecu.dev` → CNAME → `722f8863-5b0e-41eb-aee0-7f9c3d7ea131.cfargotunnel.com`
- Cloudflare accepted these records because CNAMEs can point anywhere
- Services were accessible via `https://forgejo.jgrecu.dev`

### After (v1.22.0 - Broken)
- external-dns changed Gateway API source behavior
- Now creates **A records** pointing directly to Gateway `.status.addresses[].value`
- Example: `forgejo.jgrecu.dev` → A → `192.168.1.168`
- **Cloudflare API rejects** proxied A records with private IPs (RFC 1918)
- Error: `"Target 192.168.1.168 is not allowed for a proxied record"`
- All external services became unreachable

## Timeline

- **2026-09-13 14:07 UTC**: Renovate upgraded external-dns 1.21.1 → 1.22.0
- **2026-09-13 14:16 UTC**: external-dns pod restarted with v1.22.0
- **2026-09-13 14:16 UTC**: external-dns deleted all CNAME records, tried to create A records
- **2026-09-13 14:16 UTC**: Cloudflare API started rejecting all DNS updates
- **2026-09-14 13:44 UTC**: Downgraded to v1.21.1, services restored

## Root Cause Analysis

### v1.22.0 Behavioral Change

In v1.22.0, the Gateway API source (`gateway-httproute`) changed how it determines DNS targets:

1. **Before (v1.21.1)**: Used existing DNS records or inferred from cluster topology
2. **After (v1.22.0)**: Reads Gateway `.status.addresses[].value` directly

```yaml
# Gateway status shows private IP
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: envoy-external
status:
  addresses:
    - type: IPAddress
      value: 192.168.1.168  # ← v1.22.0 uses this for A records
```

### Why the `target` Annotation Doesn't Work

The `external-dns.kubernetes.io/target` annotation (which forces CNAME records) is **not honored** by the `gateway-httproute` source. This annotation works for:
- `service` source
- `ingress` source
- `contour-httpproxy` source

But **NOT for**:
- `gateway-httproute` source (our case)
- `gateway-grpcroute` source
- `gateway-tlsroute` source

The Gateway API source determines targets from Gateway resources, not from HTTPRoute annotations.

## Current Solution

### 1. Pin external-dns to v1.21.1

**File:** `templates/config/kubernetes/apps/network/cloudflare-dns/app/ocirepository.yaml.j2`

```yaml
ref:
  tag: 1.21.1  # Pinned: v1.22.0+ breaks with Cloudflare Tunnel
```

### 2. Prevent Renovate Auto-Upgrade

**File:** `.renovaterc.json5`

```json5
packageRules: [
  {
    description: 'Pin external-dns to v1.21.1 - v1.22.0+ breaks with Cloudflare Tunnel setup',
    enabled: false,
    matchPackageNames: [
      'ghcr.io/home-operations/charts-mirror/external-dns',
    ],
    matchCurrentVersion: '1.21.1',
  },
  // ... other rules
]
```

## Monitoring for Upstream Fixes

### Relevant Upstream Issues

Track these GitHub issues for resolution:

1. **Gateway API target override support**
   - Issue: https://github.com/kubernetes-sigs/external-dns/issues/4821
   - Status: Feature request for `external-dns.kubernetes.io/target` support in Gateway API sources
   - When fixed: Will allow HTTPRoute annotations to override Gateway IP

2. **Private IP handling with Cloudflare**
   - Issue: https://github.com/kubernetes-sigs/external-dns/issues/4850
   - Status: Bug report for Cloudflare + Gateway API + private IP combination
   - When fixed: Should auto-detect Cloudflare Tunnel and create CNAME records

3. **external-dns v1.22.0 release notes**
   - URL: https://github.com/kubernetes-sigs/external-dns/releases/tag/v0.22.0
   - Check for patches: v0.22.1, v0.22.2, etc.

### How to Test for Fix

When a new external-dns version is released (v1.22.1+, v1.23.0+), test in a controlled way:

#### Step 1: Check Release Notes

Look for mentions of:
- Gateway API + Cloudflare fixes
- Private IP + proxied record handling
- `target` annotation support for Gateway sources
- CNAME vs A record logic changes

#### Step 2: Test in Staging (if available)

Or test during a maintenance window:

```bash
# 1. Backup current DNS records in Cloudflare dashboard
#    Dashboard → DNS → Records → Export

# 2. Temporarily upgrade external-dns
vi templates/config/kubernetes/apps/network/cloudflare-dns/app/ocirepository.yaml.j2
# Change: tag: 1.21.1  →  tag: 1.22.1 (or whatever version)

# 3. Regenerate and apply
task configure --yes
git add -A && git commit -m "test: try external-dns v1.22.1"
git push

# 4. Watch external-dns logs
kubectl logs -n network deployment/cloudflare-dns --tail=50 --follow

# 5. Look for:
#    - "type=CNAME" in logs (good!)
#    - "type=A" with content=192.168.1.168 (bad!)
#    - Cloudflare API errors with code 9003 (bad!)

# 6. Test DNS resolution
dig forgejo.jgrecu.dev +short
curl -I https://forgejo.jgrecu.dev

# 7. If it works:
#    - Update Renovate rule to allow auto-upgrade
#    - Remove the pin comment
#    - Update this document

# 8. If it fails:
#    - Rollback immediately
git revert HEAD
git push --force-with-lease
#    - Wait for next release
#    - Update GitHub issues with test results
```

#### Step 3: Verify CNAME Records Created

```bash
# Check external-dns logs for CNAME creation
kubectl logs -n network deployment/cloudflare-dns | grep "type=CNAME"

# Should see lines like:
# time="..." level=info msg="Changing record." action=CREATE record=forgejo.jgrecu.dev ttl=1 type=CNAME zone=...

# If you see type=A instead, the issue is NOT fixed
```

#### Step 4: Test All External Services

```bash
# Test each external service
for service in forgejo linkding nextcloud immich kavita grimmory woodpecker echo; do
  echo "Testing $service.jgrecu.dev..."
  curl -s -o /dev/null -w "$service: %{http_code}\n" https://$service.jgrecu.dev --max-time 5
done

# All should return 200 (or 301/302 for redirects)
```

## Alternative Solutions (Future)

If upstream never fixes this, consider these alternatives:

### Option A: Disable external-dns for Gateway API

Manually manage DNS records in Cloudflare dashboard or via Terraform:

```hcl
# terraform/dns.tf
resource "cloudflare_record" "forgejo" {
  zone_id = var.cloudflare_zone_id
  name    = "forgejo"
  value   = "722f8863-5b0e-41eb-aee0-7f9c3d7ea131.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
}
```

**Pros:**
- Full control over DNS records
- No dependency on external-dns Gateway API support

**Cons:**
- Manual updates when adding/removing services
- No automatic sync with cluster state

### Option B: Use Ingress Instead of Gateway API

Switch from HTTPRoute to Ingress resources:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: forgejo
  annotations:
    external-dns.kubernetes.io/target: "722f8863-5b0e-41eb-aee0-7f9c3d7ea131.cfargotunnel.com"
spec:
  rules:
    - host: forgejo.jgrecu.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: forgejo-http
                port:
                  number: 3000
```

**Pros:**
- `target` annotation works with Ingress source
- external-dns can be upgraded

**Cons:**
- Requires switching from Envoy Gateway to Ingress controller
- Major architectural change
- Lose Gateway API features

### Option C: Disable Cloudflare Proxy

Set `--cloudflare-proxied=false` in external-dns:

```yaml
extraArgs:
  - --cloudflare-proxied=false  # Allow private IPs
```

**Pros:**
- external-dns v1.22.0+ would work

**Cons:**
- Lose Cloudflare proxy benefits (DDoS protection, caching, analytics)
- Expose internal IPs in DNS (security concern)
- Requires port forwarding on home router

## Related Files

- `templates/config/kubernetes/apps/network/cloudflare-dns/app/ocirepository.yaml.j2` - external-dns version
- `templates/config/kubernetes/apps/network/cloudflare-dns/app/helmrelease.yaml.j2` - external-dns configuration
- `.renovaterc.json5` - Renovate rules
- `kubernetes/apps/network/cloudflare-tunnel/app/helmrelease.yaml` - Cloudflare Tunnel config

## Upstream Links

- **external-dns GitHub**: https://github.com/kubernetes-sigs/external-dns
- **Release v0.22.0**: https://github.com/kubernetes-sigs/external-dns/releases/tag/v0.22.0
- **Gateway API Issues**: https://github.com/kubernetes-sigs/external-dns/labels/area%2Fgateway-api
- **Cloudflare Provider Issues**: https://github.com/kubernetes-sigs/external-dns/labels/area%2Fprovider%2Fcloudflare

## Checklist for Testing New Versions

- [ ] Check external-dns release notes for Gateway API + Cloudflare fixes
- [ ] Search GitHub issues for "gateway-api" + "cloudflare" + "private"
- [ ] Backup current Cloudflare DNS records
- [ ] Test upgrade in maintenance window
- [ ] Verify CNAME records created (not A records)
- [ ] Test all external services accessible
- [ ] Monitor external-dns logs for Cloudflare API errors
- [ ] If successful, update Renovate rule and remove pin
- [ ] If failed, rollback and document findings in GitHub issues

## Last Updated

**Date:** 2026-09-14  
**Pinned Version:** external-dns v1.21.1  
**Reason:** v1.22.0 breaks Gateway API + Cloudflare Tunnel + private IP setup  
**Next Action:** Monitor upstream for fixes in v1.22.1+, v1.23.0+
