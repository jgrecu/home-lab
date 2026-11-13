#!/usr/bin/env bash
# complete-cleanup.sh
# Finalize the production documentation cleanup:
# - Delete stale historical scripts and docs
# - Validate argo-parity.sh syntax
# - Commit and push all changes
#
# Run once from the repo root: bash complete-cleanup.sh

set -Eeuo pipefail
cd "$(git rev-parse --show-toplevel)"

echo "==> Phase 1: Delete stale files"
git rm --force \
  scripts/flux2argo.py \
  scripts/argocd-cutover.sh \
  scripts/vault-migrate-raft.sh \
  scripts/render-flux-baseline.sh \
  tests/test_flux2argo.py \
  docs/argocd-cutover.md \
  docs/rustfs-migration-analysis.md \
  docs/volsync-setup.md

echo ""
echo "==> Phase 2: Validate argo-parity.sh syntax"
bash -n scripts/argo-parity.sh && echo "  bash -n: OK"

echo ""
echo "==> Phase 3: Validate no stale template references remain"
HITS=$(grep -r "cluster\.toml\|just configure\|templates/" docs/ README.md 2>/dev/null | wc -l)
if [[ "$HITS" -eq 0 ]]; then
  echo "  grep validation: OK (0 matches)"
else
  echo "  WARNING: $HITS stale reference(s) found:"
  grep -r "cluster\.toml\|just configure\|templates/" docs/ README.md 2>/dev/null || true
fi

echo ""
echo "==> Phase 4: Stage all changes"
git add -A

echo ""
echo "==> Phase 5: Commit"
git commit -m "docs: production cleanup — remove template system references

- Move normalise() from render-flux-baseline.sh into argo-parity.sh
- Delete historical scripts: flux2argo.py, argocd-cutover.sh,
  vault-migrate-raft.sh, render-flux-baseline.sh
- Delete historical docs: argocd-cutover.md, rustfs-migration-analysis.md,
  volsync-setup.md
- Delete tests/test_flux2argo.py
- Rewrite README.md for production state (Vault+ESO, no templates)
- Rewrite docs/README.md as full architecture index
- Update all docs: remove cluster.toml/just configure/templates/ references
- Update SECRET_MANAGEMENT.md: only vault-kms.sops.yaml remains SOPS
- Update resource-optimization-before-after.md: fix rollback procedures,
  update status of completed tasks"

echo ""
echo "==> Phase 6: Push"
git push

echo ""
echo "✅ All done."
