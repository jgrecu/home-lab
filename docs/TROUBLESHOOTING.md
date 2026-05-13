# Troubleshooting Guide

This guide provides diagnostic procedures and solutions for common issues in the homelab Kubernetes cluster.

## Table of Contents

1. [Quick Diagnostics](#quick-diagnostics)
2. [Flux GitOps Issues](#flux-gitops-issues)
3. [Pod Failures](#pod-failures)
4. [Storage Issues](#storage-issues)
5. [Network Issues](#network-issues)
6. [Certificate Problems](#certificate-problems)
7. [Backup Failures](#backup-failures)
8. [Performance Issues](#performance-issues)
9. [Monitoring & Alerting](#monitoring--alerting)

---

## Quick Diagnostics

### Fast Cluster Health Check

```bash
# Overall cluster status
task status

# Or manual check
kubectl get nodes
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
flux get kustomizations -A | grep -v "True.*Applied"
```

### Check Resource Usage

```bash
# Node resource usage
kubectl top nodes

# Top CPU consumers
kubectl top pods -A --sort-by=cpu | head -20

# Top memory consumers
kubectl top pods -A --sort-by=memory | head -20
```

### Recent Cluster Events

```bash
# Recent warnings
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' | tail -20

# All recent events
kubectl get events -A --sort-by='.lastTimestamp' | tail -50
```

---

## Flux GitOps Issues

### Kustomization Not Reconciling

**Symptom:** `flux get kustomizations` shows "False" status or stuck reconciliation.

**Diagnosis:**

```bash
# Check Kustomization status
flux get kustomizations -A

# Detailed status for specific Kustomization
kubectl -n flux-system describe kustomization <name>

# Check Flux logs
flux logs --all-namespaces --follow
```

**Common Causes & Solutions:**

1. **Source not ready:**
   ```bash
   # Check GitRepository status
   flux get sources git -A
   
   # Force reconcile source
   flux reconcile source git flux-system
   ```

2. **Invalid YAML or Kustomize build error:**
   ```bash
   # Test build locally
   kustomize build kubernetes/apps/<namespace>/<app>
   
   # Validate manifests
   kubeconform kubernetes/apps/<namespace>/<app>
   ```

3. **Dependency not ready:**
   ```bash
   # Check dependencies
   kubectl -n flux-system get kustomization <name> -o jsonpath='{.spec.dependsOn}'
   
   # Ensure dependencies are reconciled first
   flux reconcile kustomization <dependency-name>
   ```

4. **Resource conflicts:**
   ```bash
   # Check for existing resources
   kubectl get <resource-kind> -n <namespace> <resource-name>
   
   # If stuck, force prune
   flux suspend kustomization <name>
   kubectl delete <resource>
   flux resume kustomization <name>
   ```

### HelmRelease Failures

**Symptom:** HelmRelease shows "False" ready status, upgrade failures.

**Diagnosis:**

```bash
# Check HelmRelease status
flux get helmreleases -A

# Detailed status
kubectl -n <namespace> describe helmrelease <name>

# Check Helm controller logs
kubectl -n flux-system logs -l app=helm-controller --tail=100
```

**Common Causes & Solutions:**

1. **Chart download failure:**
   ```bash
   # Check HelmRepository
   flux get sources helm -A
   
   # Force reconcile repository
   flux reconcile source helm <repo-name> -n flux-system
   ```

2. **Values validation error:**
   ```bash
   # Check values in HelmRelease
   kubectl -n <namespace> get helmrelease <name> -o yaml
   
   # Test values locally
   helm template <release-name> <chart-repo>/<chart-name> -f values.yaml
   ```

3. **Upgrade timeout:**
   ```bash
   # Increase timeout in HelmRelease spec
   spec:
     timeout: 10m  # Increase from default 5m
   
   # Force retry
   flux reconcile helmrelease <name> -n <namespace>
   ```

4. **Failed hooks:**
   ```bash
   # Check Helm secrets
   kubectl -n <namespace> get secrets -l owner=helm
   
   # Check hook jobs
   kubectl -n <namespace> get jobs
   
   # Delete failed hooks
   kubectl -n <namespace> delete job <hook-job-name>
   flux reconcile helmrelease <name> -n <namespace>
   ```

### SOPS Decryption Errors

**Symptom:** Secrets not decrypted, Flux shows decryption errors.

**Diagnosis:**

```bash
# Check SOPS age key secret exists
kubectl -n flux-system get secret sops-age

# Check Kustomization SOPS configuration
kubectl -n flux-system get kustomization <name> -o yaml | grep -A 5 decryption

# Check Flux logs for SOPS errors
flux logs --kind=Kustomization --name=<name>
```

**Common Causes & Solutions:**

1. **Missing age key:**
   ```bash
   # Verify age key is in cluster
   kubectl -n flux-system get secret sops-age -o jsonpath='{.data.age\.agekey}' | base64 -d
   
   # Re-create if missing
   cat age.key | kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=/dev/stdin
   ```

2. **Wrong SOPS configuration:**
   ```bash
   # Check .sops.yaml has correct age public key
   cat .sops.yaml
   
   # Re-encrypt if needed
   sops updatekeys <file>.sops.yaml
   ```

3. **Secret not properly encrypted:**
   ```bash
   # Verify encryption
   grep "sops:" <file>.sops.yaml
   
   # Re-encrypt
   sops --encrypt --in-place <file>.yaml
   mv <file>.yaml <file>.sops.yaml
   ```

---

## Pod Failures

### CrashLoopBackOff

**Symptom:** Pod repeatedly crashes and restarts.

**Diagnosis:**

```bash
# Find crashlooping pods
kubectl get pods -A | grep CrashLoopBackOff

# Check pod logs (current and previous)
kubectl -n <namespace> logs <pod-name> --previous

# Check pod events
kubectl -n <namespace> describe pod <pod-name>
```

**Common Causes & Solutions:**

1. **Application error:**
   - Check logs for error messages
   - Verify configuration (ConfigMaps, Secrets)
   - Check environment variables

2. **Missing dependencies:**
   ```bash
   # Check readiness probes
   kubectl -n <namespace> get pod <pod-name> -o yaml | grep -A 10 readinessProbe
   
   # Check if dependent services are ready
   kubectl -n <namespace> get svc
   kubectl -n <namespace> get endpoints <service-name>
   ```

3. **Resource limits too low:**
   ```bash
   # Check if OOMKilled
   kubectl -n <namespace> describe pod <pod-name> | grep -i oom
   
   # Increase memory limit in template
   # templates/config/kubernetes/apps/<namespace>/<app>/helmrelease.yaml.j2
   resources:
     limits:
       memory: 1Gi  # Increase from current value
   ```

4. **Liveness probe too aggressive:**
   ```bash
   # Check liveness probe settings
   kubectl -n <namespace> get pod <pod-name> -o yaml | grep -A 10 livenessProbe
   
   # Adjust in template (increase initialDelaySeconds, periodSeconds)
   ```

### ImagePullBackOff

**Symptom:** Pod cannot pull container image.

**Diagnosis:**

```bash
# Find pods with ImagePullBackOff
kubectl get pods -A | grep ImagePullBackOff

# Check detailed error
kubectl -n <namespace> describe pod <pod-name> | grep -A 10 "Failed to pull image"
```

**Common Causes & Solutions:**

1. **Image does not exist:**
   ```bash
   # Verify image exists
   docker pull <image>:<tag>
   
   # Check for typos in image name
   kubectl -n <namespace> get pod <pod-name> -o yaml | grep image:
   ```

2. **Registry authentication failure:**
   ```bash
   # Check imagePullSecrets
   kubectl -n <namespace> get pod <pod-name> -o yaml | grep imagePullSecrets
   
   # Verify secret exists
   kubectl -n <namespace> get secret <pull-secret-name>
   ```

3. **Rate limit exceeded:**
   - For Docker Hub, add authentication token
   - Use image mirror (Spegel in-cluster)
   - Wait and retry

4. **Network connectivity:**
   ```bash
   # Test from node
   talosctl -n <node-ip> read /etc/resolv.conf
   talosctl -n <node-ip> get addresses
   ```

### Pending Pods

**Symptom:** Pod stuck in "Pending" state, not scheduled.

**Diagnosis:**

```bash
# Find pending pods
kubectl get pods -A --field-selector=status.phase=Pending

# Check scheduling failure reason
kubectl -n <namespace> describe pod <pod-name> | grep -A 10 "Events:"
```

**Common Causes & Solutions:**

1. **Insufficient resources:**
   ```bash
   # Check node resource allocation
   kubectl describe nodes | grep -A 10 "Allocated resources"
   
   # Solution: Reduce resource requests or add nodes
   ```

2. **PVC not available:**
   ```bash
   # Check PVC status
   kubectl -n <namespace> get pvc
   
   # See Storage Issues section
   ```

3. **Node selector/affinity mismatch:**
   ```bash
   # Check pod node selector
   kubectl -n <namespace> get pod <pod-name> -o yaml | grep -A 5 nodeSelector
   
   # Check node labels
   kubectl get nodes --show-labels
   ```

4. **Taints and tolerations:**
   ```bash
   # Check node taints
   kubectl describe nodes | grep Taints
   
   # Check pod tolerations
   kubectl -n <namespace> get pod <pod-name> -o yaml | grep -A 5 tolerations
   ```

---

## Storage Issues

### PVC Stuck in Pending

**Symptom:** PersistentVolumeClaim remains in "Pending" state.

**Diagnosis:**

```bash
# Check PVC status
kubectl -n <namespace> get pvc

# Check PVC events
kubectl -n <namespace> describe pvc <pvc-name>

# Check StorageClass
kubectl get storageclass
```

**Common Causes & Solutions:**

1. **No available storage:**
   ```bash
   # Check Longhorn volumes
   kubectl -n longhorn-system get volumes
   
   # Check Longhorn node storage
   kubectl -n longhorn-system get nodes
   ```

2. **StorageClass not found:**
   ```bash
   # Verify StorageClass exists
   kubectl get storageclass
   
   # Fix PVC to reference correct class
   spec:
     storageClassName: longhorn  # Use correct name
   ```

3. **Volume provisioner error:**
   ```bash
   # Check Longhorn manager logs
   kubectl -n longhorn-system logs -l app=longhorn-manager --tail=100
   
   # Check CSI provisioner logs
   kubectl -n longhorn-system logs -l app=csi-provisioner --tail=100
   ```

### Longhorn Volumes Degraded

**Symptom:** Longhorn volume shows degraded status, replica failures.

**Diagnosis:**

```bash
# Check Longhorn volumes
kubectl -n longhorn-system get volumes

# Check Longhorn UI
# Access at https://longhorn.<domain>

# Check replica status
kubectl -n longhorn-system get replicas
```

**Common Causes & Solutions:**

1. **Node offline/rebooting:**
   ```bash
   # Check node status
   kubectl get nodes
   
   # Check Longhorn node status
   kubectl -n longhorn-system get nodes
   
   # Wait for node to come online; replica will auto-rebuild
   ```

2. **Disk full:**
   ```bash
   # Check disk usage on nodes
   kubectl -n longhorn-system get nodes -o yaml | grep -A 5 diskStatus
   
   # Clean up old volumes/snapshots in Longhorn UI
   ```

3. **Replica scheduling failure:**
   ```bash
   # Check Longhorn settings
   kubectl -n longhorn-system get settings
   
   # Adjust replica count or node selector
   ```

### SeaweedFS S3 Issues

**Symptom:** S3 backups failing, SeaweedFS unavailable.

**Diagnosis:**

```bash
# Check SeaweedFS pods
kubectl -n storage get pods -l app=seaweedfs

# Check S3 endpoint
curl -I http://seaweedfs-s3.storage.svc.cluster.local:8333

# Check Volsync backup logs
kubectl -n <namespace> logs -l app.kubernetes.io/name=volsync --tail=100
```

**Common Causes & Solutions:**

1. **SeaweedFS master unavailable:**
   ```bash
   # Check master pods
   kubectl -n storage get pods -l app=seaweedfs-master
   
   # Check master logs
   kubectl -n storage logs -l app=seaweedfs-master --tail=100
   
   # Restart if needed
   kubectl -n storage rollout restart deployment seaweedfs-master
   ```

2. **Volume server issues:**
   ```bash
   # Check volume servers
   kubectl -n storage get pods -l app=seaweedfs-volume
   
   # Check volume logs
   kubectl -n storage logs -l app=seaweedfs-volume --tail=100
   ```

3. **S3 credentials incorrect:**
   ```bash
   # Verify S3 secret
   kubectl -n <namespace> get secret volsync-restic-secret -o yaml
   
   # Re-create if needed (from cluster.yaml values)
   ```

---

## Network Issues

### Service Unreachable

**Symptom:** Cannot access service from within or outside cluster.

**Diagnosis:**

```bash
# Check service exists
kubectl -n <namespace> get svc <service-name>

# Check endpoints
kubectl -n <namespace> get endpoints <service-name>

# Test from debug pod
kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- curl http://<service-name>.<namespace>.svc.cluster.local
```

**Common Causes & Solutions:**

1. **No healthy pods:**
   ```bash
   # Check pod status
   kubectl -n <namespace> get pods -l app.kubernetes.io/name=<app>
   
   # Check pod readiness
   kubectl -n <namespace> describe pod <pod-name> | grep Readiness
   ```

2. **Service selector mismatch:**
   ```bash
   # Check service selector
   kubectl -n <namespace> get svc <service-name> -o yaml | grep -A 5 selector
   
   # Check pod labels
   kubectl -n <namespace> get pods --show-labels
   
   # Ensure selector matches pod labels
   ```

3. **NetworkPolicy blocking:**
   ```bash
   # Check NetworkPolicies
   kubectl -n <namespace> get networkpolicies
   
   # Describe policy
   kubectl -n <namespace> describe networkpolicy <policy-name>
   
   # Temporarily delete to test
   kubectl -n <namespace> delete networkpolicy <policy-name>
   ```

4. **Port mismatch:**
   ```bash
   # Verify service port matches container port
   kubectl -n <namespace> get svc <service-name> -o yaml
   kubectl -n <namespace> get pod <pod-name> -o yaml | grep -A 5 ports
   ```

### Ingress Not Working

**Symptom:** External URL not accessible, 404 or connection timeout.

**Diagnosis:**

```bash
# Check Ingress resource
kubectl -n <namespace> get ingress

# Check Ingress status
kubectl -n <namespace> describe ingress <ingress-name>

# Check Envoy Gateway
kubectl -n network get pods -l app=envoy-gateway
```

**Common Causes & Solutions:**

1. **Gateway not ready:**
   ```bash
   # Check Gateway status
   kubectl -n network get gateway
   
   # Check Envoy proxy pods
   kubectl -n network get pods -l gateway.envoyproxy.io/owning-gateway-name=<gateway-name>
   ```

2. **HTTPRoute not configured:**
   ```bash
   # Check HTTPRoute
   kubectl -n <namespace> get httproute
   
   # Verify route matches hostname
   kubectl -n <namespace> get httproute <route-name> -o yaml | grep hostnames
   ```

3. **DNS not resolving:**
   ```bash
   # Test DNS resolution
   nslookup <hostname>
   
   # Check k8s-gateway
   kubectl -n network get pods -l app.kubernetes.io/name=k8s-gateway
   ```

4. **Cloudflare tunnel issue:**
   ```bash
   # Check cloudflare-tunnel status
   kubectl -n network get pods -l app.kubernetes.io/name=cloudflare-tunnel
   
   # Check tunnel logs
   kubectl -n network logs -l app.kubernetes.io/name=cloudflare-tunnel --tail=100
   ```

### DNS Resolution Failures

**Symptom:** Pods cannot resolve domain names.

**Diagnosis:**

```bash
# Test DNS from pod
kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- nslookup google.com

# Check CoreDNS
kubectl -n kube-system get pods -l k8s-app=kube-dns

# Check CoreDNS logs
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50
```

**Common Causes & Solutions:**

1. **CoreDNS pods not ready:**
   ```bash
   # Check CoreDNS status
   kubectl -n kube-system get pods -l k8s-app=kube-dns
   
   # Restart if needed
   kubectl -n kube-system rollout restart deployment coredns
   ```

2. **CoreDNS ConfigMap error:**
   ```bash
   # Check ConfigMap
   kubectl -n kube-system get configmap coredns -o yaml
   
   # Validate Corefile syntax
   ```

3. **Cluster DNS not configured on pods:**
   ```bash
   # Check pod DNS config
   kubectl -n <namespace> get pod <pod-name> -o yaml | grep -A 5 dnsPolicy
   
   # Should be ClusterFirst
   ```

---

## Certificate Problems

### Certificate Not Ready

**Symptom:** Certificate shows "False" ready status, Ingress has no TLS.

**Diagnosis:**

```bash
# Check Certificate status
kubectl -n <namespace> get certificate

# Check detailed status
kubectl -n <namespace> describe certificate <cert-name>

# Check cert-manager logs
kubectl -n cert-manager logs -l app=cert-manager --tail=100
```

**Common Causes & Solutions:**

1. **ACME challenge failing:**
   ```bash
   # Check CertificateRequest
   kubectl -n <namespace> get certificaterequest
   
   # Check Challenge
   kubectl -n <namespace> get challenge
   kubectl -n <namespace> describe challenge <challenge-name>
   
   # Check HTTP01 challenge pod
   kubectl -n <namespace> get pods -l acme.cert-manager.io/http01-solver=true
   ```

2. **DNS01 challenge failing:**
   ```bash
   # Check Cloudflare credentials
   kubectl -n cert-manager get secret cloudflare-api-token
   
   # Verify token has DNS edit permissions
   ```

3. **Rate limit exceeded:**
   ```bash
   # Let's Encrypt rate limits: 5 duplicates/week, 50 certs/domain/week
   # Wait or use staging issuer for testing
   
   # Switch to staging issuer
   spec:
     issuerRef:
       name: letsencrypt-staging
   ```

4. **Issuer not ready:**
   ```bash
   # Check ClusterIssuer
   kubectl get clusterissuer
   kubectl describe clusterissuer letsencrypt-production
   ```

### Certificate Expiring Soon

**Symptom:** Alert for certificate expiring within 30 days.

**Diagnosis:**

```bash
# Check certificate expiry
kubectl get certificates -A -o json | jq -r '.items[] | select(.status.renewalTime != null) | "\(.metadata.namespace)/\(.metadata.name): \(.status.renewalTime)"'

# Check if renewal in progress
kubectl -n <namespace> get certificaterequest
```

**Solutions:**

1. **Trigger manual renewal:**
   ```bash
   # Delete secret to force renewal
   kubectl -n <namespace> delete secret <tls-secret-name>
   
   # cert-manager will automatically recreate
   ```

2. **Check cert-manager is running:**
   ```bash
   kubectl -n cert-manager get pods
   kubectl -n cert-manager logs -l app=cert-manager --tail=100
   ```

---

## Backup Failures

### Volsync Backups Not Running

**Symptom:** ReplicationSource shows old lastSyncTime, backups not occurring.

**Diagnosis:**

```bash
# Check ReplicationSource status
kubectl -n <namespace> get replicationsource

# Check detailed status
kubectl -n <namespace> describe replicationsource <source-name>

# Check Volsync controller logs
kubectl -n volsync-system logs -l control-plane=volsync --tail=100
```

**Common Causes & Solutions:**

1. **Restic secret missing:**
   ```bash
   # Check secret exists
   kubectl -n <namespace> get secret volsync-restic-secret
   
   # Re-create from cluster.yaml values
   ```

2. **S3 endpoint unreachable:**
   ```bash
   # Test S3 connection from pod
   kubectl run -it --rm debug --image=amazon/aws-cli --restart=Never -- \
     aws --endpoint-url=http://seaweedfs-s3.storage.svc.cluster.local:8333 s3 ls
   ```

3. **PVC not found:**
   ```bash
   # Verify source PVC exists
   kubectl -n <namespace> get pvc
   
   # Check ReplicationSource references correct PVC
   kubectl -n <namespace> get replicationsource <source-name> -o yaml | grep sourcePVC
   ```

4. **Schedule conflict:**
   ```bash
   # Check schedule
   kubectl -n <namespace> get replicationsource <source-name> -o yaml | grep schedule
   
   # Ensure not running during maintenance window
   ```

### CloudNativePG Backups Failing

**Symptom:** Postgres cluster shows old lastSuccessfulBackup timestamp.

**Diagnosis:**

```bash
# Check cluster backup status
kubectl -n database-system get cluster

# Check detailed status
kubectl -n database-system describe cluster <cluster-name> | grep -A 10 "Backup"

# Check backup pods
kubectl -n database-system get pods | grep backup

# Check logs
kubectl -n database-system logs <backup-pod-name>
```

**Common Causes & Solutions:**

1. **Barman credentials incorrect:**
   ```bash
   # Check backup secret
   kubectl -n database-system get secret <cluster-name>-pgbackrest-secrets
   
   # Re-create from cluster.yaml values
   ```

2. **Storage full:**
   ```bash
   # Check Longhorn space
   kubectl -n longhorn-system get nodes -o yaml | grep diskStatus
   
   # Clean up old backups if needed
   ```

3. **Backup schedule disabled:**
   ```bash
   # Check cluster spec
   kubectl -n database-system get cluster <cluster-name> -o yaml | grep -A 10 backup
   
   # Ensure schedule is configured
   ```

---

## Performance Issues

### High CPU Usage

**Symptom:** Node or pod CPU usage above 80%, throttling.

**Diagnosis:**

```bash
# Check node CPU
kubectl top nodes

# Check pod CPU
kubectl top pods -A --sort-by=cpu | head -20

# Check CPU throttling
kubectl get pods -A -o json | jq -r '.items[] | select(.status.containerStatuses[].lastState.terminated.reason == "OOMKilled") | "\(.metadata.namespace)/\(.metadata.name)"'
```

**Solutions:**

1. **Increase CPU limits:**
   ```bash
   # Edit template to increase CPU limits
   # templates/config/kubernetes/apps/<namespace>/<app>/helmrelease.yaml.j2
   
   resources:
     limits:
       cpu: 1000m  # Increase
   ```

2. **Identify runaway process:**
   ```bash
   # Exec into pod
   kubectl -n <namespace> exec -it <pod-name> -- top
   
   # Check application logs for errors
   kubectl -n <namespace> logs <pod-name> --tail=100
   ```

3. **Scale horizontally:**
   ```bash
   # Increase replicas
   kubectl -n <namespace> scale deployment <deployment-name> --replicas=3
   ```

### High Memory Usage

**Symptom:** Node or pod memory usage above 80%, OOMKilled.

**Diagnosis:**

```bash
# Check node memory
kubectl top nodes

# Check pod memory
kubectl top pods -A --sort-by=memory | head -20

# Check for OOMKilled pods
kubectl get events -A --field-selector reason=OOMKilling
```

**Solutions:**

1. **Increase memory limits:**
   ```bash
   # Edit template
   resources:
     limits:
       memory: 2Gi  # Increase
   ```

2. **Check for memory leaks:**
   ```bash
   # Monitor memory over time
   watch kubectl top pod <pod-name> -n <namespace>
   
   # Check application metrics in Grafana
   ```

3. **Tune application:**
   - Java: Adjust heap size (-Xmx)
   - Node.js: Adjust --max-old-space-size
   - Check application documentation

### Slow Storage Performance

**Symptom:** High I/O wait, slow disk operations.

**Diagnosis:**

```bash
# Check Longhorn volume performance
# Access Longhorn UI: https://longhorn.<domain>

# Check node disk I/O
talosctl -n <node-ip> dashboard

# Check for degraded volumes
kubectl -n longhorn-system get volumes | grep -v Healthy
```

**Solutions:**

1. **Check replica locality:**
   - Prefer local replicas for performance
   - Check volume anti-affinity rules

2. **Tune Longhorn settings:**
   ```bash
   # Increase concurrent replica rebuild
   kubectl -n longhorn-system edit settings concurrent-replica-rebuild-per-node-limit
   ```

3. **Check underlying disk:**
   ```bash
   # Check disk health
   talosctl -n <node-ip> read /sys/block/sda/stat
   ```

---

## Monitoring & Alerting

### Prometheus Not Scraping Targets

**Symptom:** Targets show "down" in Prometheus UI, no metrics.

**Diagnosis:**

```bash
# Check ServiceMonitor
kubectl -n <namespace> get servicemonitor

# Check if selector matches service
kubectl -n <namespace> get svc <service-name> --show-labels

# Check Prometheus logs
kubectl -n observability logs -l app.kubernetes.io/name=prometheus --tail=100
```

**Common Causes & Solutions:**

1. **ServiceMonitor selector mismatch:**
   ```bash
   # Check ServiceMonitor selector
   kubectl -n <namespace> get servicemonitor <name> -o yaml | grep -A 5 selector
   
   # Check Service labels
   kubectl -n <namespace> get svc <service-name> -o yaml | grep -A 5 labels
   
   # Ensure they match
   ```

2. **Metrics port not exposed:**
   ```bash
   # Check service ports
   kubectl -n <namespace> get svc <service-name> -o yaml | grep -A 10 ports
   
   # Verify metrics endpoint
   kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- \
     curl http://<service-name>.<namespace>.svc.cluster.local:<port>/metrics
   ```

3. **NetworkPolicy blocking Prometheus:**
   ```bash
   # Check NetworkPolicies in namespace
   kubectl -n <namespace> get networkpolicies
   
   # Ensure Prometheus can scrape
   # Add allow rule for prometheus namespace
   ```

4. **Prometheus ServiceMonitor selector:**
   ```bash
   # Check Prometheus CRD for serviceMonitorSelector
   kubectl -n observability get prometheus -o yaml | grep -A 5 serviceMonitorSelector
   
   # Ensure ServiceMonitor has matching label
   ```

### Grafana Dashboards Not Loading

**Symptom:** Dashboard shows "No data" or fails to load.

**Diagnosis:**

```bash
# Check Grafana pod
kubectl -n observability get pods -l app.kubernetes.io/name=grafana

# Check Grafana logs
kubectl -n observability logs -l app.kubernetes.io/name=grafana --tail=100

# Check data source
# Access Grafana UI → Configuration → Data Sources
```

**Common Causes & Solutions:**

1. **Data source not configured:**
   ```bash
   # Check Grafana data sources ConfigMap
   kubectl -n observability get configmap grafana-datasources -o yaml
   
   # Ensure Prometheus URL is correct
   http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090
   ```

2. **Wrong Prometheus query:**
   - Test query in Prometheus UI first
   - Check metric name and labels

3. **Time range issue:**
   - Adjust dashboard time range
   - Check if metrics exist for selected period

### Loki Not Receiving Logs

**Symptom:** No logs in Grafana Explore, Loki queries return empty.

**Diagnosis:**

```bash
# Check Loki pods
kubectl -n observability get pods -l app.kubernetes.io/name=loki

# Check Fluent-bit (log collector)
kubectl -n observability get pods -l app.kubernetes.io/name=fluent-bit

# Check Fluent-bit logs
kubectl -n observability logs -l app.kubernetes.io/name=fluent-bit --tail=100
```

**Common Causes & Solutions:**

1. **Fluent-bit not shipping:**
   ```bash
   # Check Fluent-bit output config
   kubectl -n observability get configmap fluent-bit -o yaml
   
   # Verify Loki endpoint
   http://loki-gateway.observability.svc.cluster.local:80/loki/api/v1/push
   ```

2. **Loki storage full:**
   ```bash
   # Check Loki PVC
   kubectl -n observability get pvc -l app.kubernetes.io/name=loki
   
   # Check usage
   kubectl -n observability exec -it <loki-pod> -- df -h
   ```

3. **Log format parsing error:**
   - Check Fluent-bit parser configuration
   - Test log format matches parser

---

## General Troubleshooting Tips

### 1. Always Check the Source

**Remember:** This cluster uses GitOps. Always fix issues in templates, not directly in the cluster.

```bash
# DON'T do this:
kubectl edit deployment myapp

# DO this instead:
# 1. Edit templates/config/kubernetes/apps/<namespace>/<app>/helmrelease.yaml.j2
# 2. Run: task configure --yes
# 3. Commit and push
# 4. Flux will reconcile automatically
```

### 2. Progressive Debugging

Start broad, narrow down:

1. Cluster-level: `kubectl get nodes`, `flux get kustomizations -A`
2. Namespace-level: `kubectl -n <namespace> get all`
3. Resource-level: `kubectl -n <namespace> describe <resource>`
4. Container-level: `kubectl -n <namespace> logs <pod>`

### 3. Use Debug Containers

```bash
# Run debug pod
kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- bash

# Or attach ephemeral container (Kubernetes 1.23+)
kubectl debug -it <pod-name> --image=nicolaka/netshoot --target=<container-name>
```

### 4. Check Recent Changes

```bash
# Git history
git log --oneline -10

# Recent commits
git show HEAD

# Flux reconciliation history
flux logs --all-namespaces --since=1h
```

### 5. Leverage Monitoring

- Check Grafana dashboards for resource usage trends
- Check Gatus for service health status
- Check Prometheus alerts for active warnings

### 6. Clean Up Commits After Troubleshooting

After fixing an issue through multiple attempts, squash commits:

```bash
# View recent commits
git log --oneline -5

# Squash last 3 commits
git rebase -i HEAD~3

# Mark commits 2 and 3 as 'squash'
# Edit commit message
# Force push
git push --force-with-lease
```

---

## When to Ask for Help

If you've tried the above steps and still cannot resolve the issue:

1. **Gather diagnostic information:**
   ```bash
   # Collect logs
   kubectl -n <namespace> logs <pod-name> > pod.log
   
   # Collect events
   kubectl -n <namespace> get events --sort-by='.lastTimestamp' > events.log
   
   # Collect resource definitions
   kubectl -n <namespace> get <resource> <name> -o yaml > resource.yaml
   ```

2. **Check GitHub issues:**
   - Check upstream project issues
   - Search for similar errors

3. **Check community resources:**
   - Kubernetes Slack
   - Reddit r/kubernetes
   - Stack Overflow

4. **Document your findings:**
   - What was tried
   - What didn't work
   - Error messages
   - Environment details

---

## Quick Reference Commands

```bash
# Cluster health
task status
kubectl get nodes
flux get kustomizations -A

# Pod debugging
kubectl get pods -A --field-selector=status.phase!=Running
kubectl -n <namespace> logs <pod> --previous
kubectl -n <namespace> describe pod <pod>

# Resource usage
kubectl top nodes
kubectl top pods -A --sort-by=cpu
kubectl top pods -A --sort-by=memory

# Network debugging
kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- bash

# Storage debugging
kubectl get pvc -A
kubectl -n longhorn-system get volumes

# Flux debugging
flux logs --all-namespaces --follow
flux reconcile kustomization <name> --with-source

# Talos debugging
talosctl -n <node-ip> dashboard
talosctl -n <node-ip> logs <service>
```

---

**Remember:** Most issues in this GitOps cluster are resolved by:
1. Identifying the problem
2. Fixing the template in `templates/config/`
3. Running `task configure --yes`
4. Committing and pushing
5. Letting Flux reconcile

Direct cluster edits are temporary and will be overwritten!

---

## Verification After Fixes

After applying any troubleshooting fix, verify the resolution:

### Expected Outcomes
- **Pods**: All pods should reach `Running` or `Completed` status
  ```bash
  kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
  # Expected: No results (empty)
  ```

- **Flux**: All kustomizations should show `True` and `Applied`
  ```bash
  flux get kustomizations -A | grep -v "True.*Applied"
  # Expected: No results (empty)
  ```

- **Cluster Health**: Nodes should be `Ready`, no recent warnings
  ```bash
  kubectl get nodes
  # Expected: All nodes STATUS = Ready
  
  kubectl get events -A --field-selector type=Warning --since=10m
  # Expected: No new warnings related to the fixed issue
  ```

- **Service Availability**: Test the affected service
  ```bash
  curl -f https://<service-url>/health
  # Expected: HTTP 200 OK
  ```
