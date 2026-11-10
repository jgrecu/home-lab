# Flux → Argo CD cut-over runbook

In-place migration of the running cluster from Flux (flux-operator) to Argo CD.
Workloads, PVCs and data are **adopted**, never recreated. Every step is executed with
`scripts/argocd-cutover.sh <phase>` — dry-run by default, `--apply` to execute (asks before
each change). State (PVC UIDs, Helm release list, diffs) is kept in `.tmp/cutover/`.

> Read the whole runbook before starting. Plan ~2 hours, nothing exposed to the internet
> changes except the GitHub webhook URL.

## What changes and what does not

| Stays exactly the same | Changes |
|---|---|
| Every workload, PVC, Secret, Service, HTTPRoute (parity-checked: 52/60 identical renders, 8 intended diffs) | GitOps controller: Flux → Argo CD (`argo-system`) |
| Helm release names and namespaces | Helm release secrets become orphaned metadata (deleted in cleanup) |
| Vault (Raft, AWS KMS auto-unseal), volsync schedules | Flux dashboards/alerts/KSM metrics → Argo CD dashboard + alerts |
| | Argo CD UI on `envoy-internal`; only `/api/webhook` on `envoy-external` |

Intended render differences (see `.tmp/parity` after `scripts/argo-parity.sh`): homepage
(duplicate SA removed), grimmory (`Recreate`), forgejo-runner (data PVC) — all three now
equal the **live** objects; grafana / kube-prometheus-stack / vault (Flux-only bits removed);
tuppr-policies (`namespace:` on cluster-scoped CRs, ignored by the API).

## Rollback points

| After phase | Rollback |
|---|---|
| precheck, backup, install-argo | `helm -n argo-system uninstall argo-cd && kubectl delete ns argo-system` — Flux never stopped |
| freeze-flux | Flux CRs are gone but workloads run. Re-bootstrap Flux from `main` **before** the merge: `git checkout <pre-merge-sha> && just bootstrap bootstrap-apps` (installs flux-operator/instance, Flux re-adopts by the same names) |
| adopt / sync | Disable auto-sync of the offending Application (`kubectl -n argo-system patch application <app> --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'`), fix in git, re-sync. Nothing is pruned on first adoption (new Applications own no resources yet) |

**Stop immediately** if the script reports changed PVC UIDs.

## Phase 0 — Prepare (no cluster changes)

1. Push the branch and open a PR to `main`; **do not merge**:
   `git push -u origin feat/argocd-migration`
2. Wait for the `Kubernetes` workflow (fake values, throwaway key) and `e2e` to pass.
3. Tools: `mise install` (argocd 3.6.1, ksops 4.5.1, flux 2.10.0 still needed).
4. Have ready: Vault recovery keys + root token, GitHub repo admin (webhook).

## Phase 1 — Precheck and backup

```bash
git switch feat/argocd-migration
./scripts/argocd-cutover.sh precheck            # read-only, records PVC UIDs + Helm releases
./scripts/argocd-cutover.sh backup --apply      # one-off volsync backup of every PVC (local + R2)
just ops vault-snapshot-now                     # extra Raft snapshot to R2
```
Go/no-go: no warnings from precheck (all Flux objects Ready, Vault unsealed), all backups
`Successful`.

## Phase 2 — Install Argo CD next to Flux

```bash
./scripts/argocd-cutover.sh install-argo          # review dry-run
./scripts/argocd-cutover.sh install-argo --apply
kubectl -n argo-system get pods                    # all Running; repo-server init 'download-tools' completed
kubectl -n argo-system logs deploy/argocd-repo-server -c download-tools | tail -5   # checksums OK
```
Argo CD has no Applications yet, so it changes nothing.

## Phase 3 — Freeze and remove Flux

```bash
./scripts/argocd-cutover.sh freeze-flux           # review: 142 suspends, operator scaled to 0
./scripts/argocd-cutover.sh freeze-flux --apply   # also re-checks PVC UIDs
kubectl get pods -A | grep -v -e Running -e Completed   # nothing new failing
```
`flux uninstall --keep-namespace` removes finalizers first, then controllers and CRDs —
workloads stay (documented Flux behaviour). From here until Phase 5 nothing reconciles
the cluster; keep the window short.

## Phase 4 — Merge and adopt

1. Merge the PR (`main` now holds the Argo CD layout).
2. Create the Applications **without auto-sync**, then the root Applications:
   ```bash
   git switch main && git pull
   ./scripts/argocd-cutover.sh adopt
   ./scripts/argocd-cutover.sh adopt --apply
   ```
3. Wave by wave, lowest first (`-10 -8 0 1 2 3 4`):
   ```bash
   ./scripts/argocd-cutover.sh diff -10          # read-only, writes .tmp/cutover/diff-<app>.txt
   ./scripts/argocd-cutover.sh sync -10 --apply  # sync + re-enable auto-sync, re-checks PVC UIDs
   ```
   Expected diffs: Argo CD tracking annotations / managed fields, removed Flux labels
   (`kustomize.toolkit.fluxcd.io/*`, `helm.toolkit.fluxcd.io/*`) and the intended changes listed
   above. Anything else (replicas, images, PVC specs, selectors): **stop and investigate**.
   Wave `-10` is Argo CD adopting itself; `-8` the namespaces (`Prune=false`).

## Phase 5 — Verify

```bash
./scripts/argocd-cutover.sh verify   # Synced/Healthy, PVC UIDs, volsync schedules, Vault
just ops status
```
Spot-check a few apps in the browser, Grafana "ArgoCD" dashboard, and that the alerts
`ArgoCDAppOutOfSync/Unhealthy` are not firing.

## Phase 6 — Cleanup

```bash
./scripts/argocd-cutover.sh cleanup --apply   # Helm release secrets + flux-system namespace
```
Manual:
1. **GitHub webhook**: Settings → Webhooks → replace the Flux receiver URL with
   `https://argo-webhook.<domain>/api/webhook`, content type `application/json`, secret =
   contents of `github-push-token.txt` (rotated token), events: push.
2. Remove leftover Flux labels (cosmetic; selfHeal does not remove foreign labels):
   `kubectl get all,pvc,cm,secret -A -l kustomize.toolkit.fluxcd.io/name -o name` → `kubectl label <obj> kustomize.toolkit.fluxcd.io/name- kustomize.toolkit.fluxcd.io/namespace-`.
3. Follow-ups (separate tasks): remove `flux` from `.mise/config.toml`, update docs;
   volsync automatic restore (deferred subtask 12); Vault → External Secrets.
