#!/usr/bin/env python3
"""flux2argo - convert Flux app templates (templates/config/kubernetes/apps) to Argo CD layout.

Per namespace:
  <ns>/<app>/ks.yaml.j2 (+ backup-ks.yaml.j2)        -> argo/apps/<ns>/<app>.yaml.j2 (Application)
  <ns>/<app>/app/helmrelease + oci/helmrepository     -> Application chart source + values(.sops).yaml.j2
  <ns>/<app>/app/<rest>                               -> <ns>/<app>/config/  (Secrets/domain files via ksops)
  <ns>/<app>/backup/                                  -> kept, Secrets via ksops, merged into the same Application
  <ns>/kustomization.yaml.j2                          -> namespace.yaml + extra resources only (namespaces app)
Flux dependsOn -> argocd.argoproj.io/sync-wave (longest dependency chain).

Usage: uv run python scripts/flux2argo.py [--namespace NS ...] [--dry-run]
"""
from __future__ import annotations

import argparse
import io
import re
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path

from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap, CommentedSeq

ROOT = Path(__file__).resolve().parent.parent
TPL = ROOT / "templates/config/kubernetes"
APPS = TPL / "apps"
RENDERED = ROOT / "kubernetes"
SKIP_NAMESPACES = {"flux-system", "argo-system"}
DOMAIN_VAR = "${SECRET_DOMAIN}"
DOMAIN_TOKEN = "__DOMAIN__"
DOMAIN_JINJA = "#{ cloudflare_domain }#"
JINJA_EXPR = re.compile(r"#\{.*?\}#")
JINJA_BLOCK = re.compile(r"#%.*?%#")
REPO_URL = ("#{ 'ssh://git@github.com/' if repository_visibility == 'private' "
            "else 'https://github.com/' }##{ repository_name }#.git")
SOURCE_FILES = {"helmrelease.yaml", "ocirepository.yaml", "helmrepository.yaml"}


def yaml_rt() -> YAML:
    y = YAML()
    y.preserve_quotes = True
    y.width = 4096
    y.indent(mapping=2, sequence=4, offset=2)
    return y


# ── Jinja-safe text handling ────────────────────────────────────────────────

def protect(text: str) -> tuple[str, list[str]]:
    """Replace #{ }# expressions by placeholders so the text parses as YAML."""
    found: list[str] = []

    def sub(m: re.Match) -> str:
        found.append(m.group(0))
        return f"__JINJA{len(found) - 1}__"
    return JINJA_EXPR.sub(sub, text), found


def restore(text: str, found: list[str]) -> str:
    for i, expr in enumerate(found):
        text = text.replace(f"__JINJA{i}__", expr)
    return text.replace(DOMAIN_TOKEN, DOMAIN_JINJA)


def flux_text(text: str) -> str:
    """Apply Flux postBuild semantics at template level: domain var + $${ un-escape."""
    return text.replace(DOMAIN_VAR, DOMAIN_JINJA).replace("$${", "${")


def has_domain(text: str) -> bool:
    return DOMAIN_VAR in text or "cloudflare_domain" in text


def load_docs(path: Path) -> tuple[list, list[str]]:
    text, found = protect(path.read_text())
    docs = [d for d in yaml_rt().load_all(text) if d is not None]
    return docs, found


def dump_docs(docs: list, found: list[str]) -> str:
    buf = io.StringIO()
    y = yaml_rt()
    y.explicit_start = True
    y.dump_all(docs, buf)
    return restore(buf.getvalue(), found)


# ── Model ───────────────────────────────────────────────────────────────────

@dataclass
class Ks:
    name: str
    path: str        # ./kubernetes/apps/<ns>/<app>/<sub>
    deps: list[str]
    target_ns: str | None
    file: Path

    @property
    def sub(self) -> str:
        return self.path.rstrip("/").rsplit("/", 1)[-1]

    @property
    def app_dir(self) -> Path:
        return ROOT / "templates/config" / self.path.removeprefix("./")


@dataclass
class AppPlan:
    name: str
    namespace: str
    root: Path                       # templates/.../apps/<ns>/<app>
    main: Ks
    extra: list[Ks] = field(default_factory=list)
    chart: dict | None = None
    wave: int = 0
    notes: list[str] = field(default_factory=list)

    @property
    def deps(self) -> set[str]:
        out = set(self.main.deps)
        for k in self.extra:
            out |= set(k.deps)
        return out - {self.name}


# ── Discovery ───────────────────────────────────────────────────────────────

def parse_ks_file(path: Path) -> list[Ks]:
    docs, _ = load_docs(path)
    return [Ks(name=d["metadata"]["name"], path=d["spec"]["path"],
               deps=[x["name"] for x in d["spec"].get("dependsOn", [])],
               target_ns=d["spec"].get("targetNamespace"), file=path)
            for d in docs if d.get("kind") == "Kustomization"]


def discover(namespace: str) -> list[Ks]:
    ns_kust, _ = load_docs(APPS / namespace / "kustomization.yaml.j2")
    out: list[Ks] = []
    for res in ns_kust[0].get("resources", []):
        if res.endswith("ks.yaml"):
            out += parse_ks_file(APPS / namespace / (res.removeprefix("./") + ".j2"))
    return out


def group(namespace: str, kss: list[Ks]) -> list[AppPlan]:
    plans: dict[Path, AppPlan] = {}
    standalone = []
    for k in kss:
        if k.sub == "app":
            plans[k.app_dir.parent] = AppPlan(k.name, namespace, k.app_dir.parent, k)
        elif k.sub != "backup":
            standalone.append(k)
    for k in kss:
        if k.sub == "backup":
            plans[k.app_dir.parent].extra.append(k)
    for k in standalone:  # e.g. vpa-sources, tuppr-policies: own Application on their dir
        plans[k.app_dir] = AppPlan(k.name, namespace, k.app_dir, k)
    return list(plans.values())


def index_chart_sources() -> dict[str, dict]:
    """name -> {kind, url, tag, renovate} for every OCIRepository/HelmRepository template."""
    index: dict[str, dict] = {}
    for f in list(APPS.rglob("ocirepository.yaml.j2")) + list(APPS.rglob("helmrepository.yaml.j2")):
        text = f.read_text()
        renovate = re.search(r"#\s*renovate:.*", text)
        for d in load_docs(f)[0]:
            if d.get("kind") in ("OCIRepository", "HelmRepository"):
                index[d["metadata"]["name"]] = {
                    "kind": d["kind"], "url": str(d["spec"]["url"]),
                    "tag": str(d["spec"].get("ref", {}).get("tag", "")),
                    "type": d["spec"].get("type", "default"),
                    "renovate": renovate.group(0) if renovate else None}
    return index


def chart_from_helmrelease(hr: CommentedMap, sources: dict[str, dict]) -> dict:
    spec = hr["spec"]
    if "chartRef" in spec:
        src = sources[spec["chartRef"]["name"]]
        repo, chart = src["url"].removeprefix("oci://").rsplit("/", 1)
        return {"repoURL": repo, "chart": chart, "version": src["tag"], "renovate": src["renovate"]}
    cs = spec["chart"]["spec"]
    src = sources[cs["sourceRef"]["name"]]
    url = src["url"]
    if src["type"] == "oci" or url.startswith("oci://"):
        url = url.removeprefix("oci://").rstrip("/")
    return {"repoURL": url, "chart": str(cs["chart"]), "version": str(cs["version"]), "renovate": None}


# ── Values split ────────────────────────────────────────────────────────────

def domain_paths(node, path=()):
    """Yield paths (tuples of keys/indices) to scalars containing the domain token."""
    if isinstance(node, dict):
        for k, v in node.items():
            yield from domain_paths(v, path + (k,))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from domain_paths(v, path + (i,))
    elif isinstance(node, str) and DOMAIN_TOKEN in node:
        yield path


def cut_point(path: tuple) -> tuple:
    """Longest all-map-key prefix: Helm deep-merges maps but replaces lists wholesale."""
    for i, part in enumerate(path):
        if isinstance(part, int):
            return path[:i]
    return path


def split_values(values: CommentedMap) -> tuple[CommentedMap, CommentedMap]:
    cuts = sorted({cut_point(p) for p in domain_paths(values)}, key=len)
    cuts = [c for c in cuts if not any(c[:len(o)] == o and c != o for o in cuts)]
    secret = CommentedMap()
    for cut in cuts:
        parent, dst = values, secret
        for key in cut[:-1]:
            parent = parent[key]
            dst = dst.setdefault(key, CommentedMap())
        dst[cut[-1]] = parent.pop(cut[-1])
        prune_empty(values, cut[:-1])
    return values, secret


def prune_empty(root: CommentedMap, path: tuple) -> None:
    while path:
        node = root
        for key in path[:-1]:
            node = node[key]
        if node[path[-1]] in ({}, None):
            del node[path[-1]]
            path = path[:-1]
        else:
            return


def dump_values(data: CommentedMap, found: list[str], header: str) -> str:
    buf = io.StringIO()
    yaml_rt().dump(data, buf)
    return header + restore(buf.getvalue(), found)


# ── Directory conversion ────────────────────────────────────────────────────

KSOPS_GENERATOR = """---
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: {name}
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
{files}"""


def is_secret_file(path: Path) -> bool:
    return path.name.endswith(".sops.yaml.j2") or path.name.endswith(".sops.yaml")


def rewrite_kustomization(directory: Path, plan: AppPlan) -> bool:
    """Rewire a kustomize dir: drop Flux sources, secrets/domain manifests via ksops.
    Returns False when nothing deployable is left (dir removed)."""
    kfile = directory / "kustomization.yaml.j2"
    docs, found = load_docs(kfile)
    kust = docs[0]
    keep, encrypted = CommentedSeq(), []
    for res in kust.get("resources", []):
        name = res.removeprefix("./")
        if name in SOURCE_FILES:
            (directory / f"{name}.j2").unlink(missing_ok=True)
            (directory / name).unlink(missing_ok=True)
            continue
        src = directory / f"{name}.j2" if (directory / f"{name}.j2").exists() else directory / name
        if src.is_file():
            text = src.read_text()
            new_text = flux_text(text)
            if is_secret_file(src):
                encrypted.append(name)
            elif has_domain(text):
                enc_name = name.removesuffix(".yaml") + ".sops.yaml"
                (directory / f"{enc_name}.j2").write_text(new_text)
                src.unlink()
                encrypted.append(enc_name)
                plan.notes.append(f"domain manifest encrypted: {directory.name}/{enc_name}")
                continue
            if new_text != text:
                src.write_text(new_text)
        keep.append(res)
    if encrypted:
        gen = directory / "secret-generator.yaml.j2"
        gen.write_text(KSOPS_GENERATOR.format(
            name=f"{plan.name}-{directory.name}-secrets",
            files="".join(f"  - ./{f}\n" for f in encrypted)))
        kust.setdefault("generators", CommentedSeq()).append("./secret-generator.yaml")
    if keep:
        kust["resources"] = keep
    elif "resources" in kust:
        del kust["resources"]
    if not any(k in kust for k in ("resources", "generators", "components")):
        shutil.rmtree(directory)
        return False
    kfile.write_text(dump_docs([kust], found))
    return True


def convert_helmrelease(app_dir: Path, plan: AppPlan, sources: dict) -> None:
    hr_file = app_dir / "helmrelease.yaml.j2"
    if not hr_file.exists():
        return
    raw = hr_file.read_text()
    if JINJA_BLOCK.search(raw):
        raise ValueError("helmrelease contains #% %# jinja blocks - convert manually")
    text, found = protect(raw.replace(DOMAIN_VAR, DOMAIN_TOKEN).replace("$${", "${"))
    hr = next(d for d in yaml_rt().load_all(text) if d and d.get("kind") == "HelmRelease")
    spec = hr["spec"]
    plan.chart = chart_from_helmrelease(hr, sources)
    plan.chart["releaseName"] = str(spec.get("releaseName", hr["metadata"]["name"]))
    for unsupported in ("postRenderers", "valuesFrom", "install", "upgrade", "timeout"):
        if unsupported in spec:
            plan.notes.append(f"HelmRelease.spec.{unsupported} not converted - review")
    plain, secret = split_values(spec.get("values") or CommentedMap())
    header = f"---\n# Helm values for {plan.chart['chart']} ({plan.name}).\n"
    (plan.root / "values.yaml.j2").write_text(dump_values(plain, found, header))
    if secret:
        (plan.root / "values.sops.yaml.j2").write_text(dump_values(
            secret, found, header.replace("values", "values with the domain (fully encrypted)", 1)))


def write_root_kustomization(plan: AppPlan, dirs: list[str]) -> None:
    kfile = plan.root / "kustomization.yaml.j2"
    if not dirs:
        kfile.unlink(missing_ok=True)
        return
    ns = plan.main.target_ns
    lines = ["---", "apiVersion: kustomize.config.k8s.io/v1beta1", "kind: Kustomization"]
    if ns:  # Flux targetNamespace overrides every namespaced resource
        lines.append(f"namespace: {ns}")
    lines += ["resources:"] + [f"  - ./{d}" for d in dirs]
    kfile.write_text("\n".join(lines) + "\n")


def convert_app(plan: AppPlan, sources: dict) -> None:
    standalone = plan.main.sub not in ("app",)
    app_dir = plan.main.app_dir
    convert_helmrelease(app_dir, plan, sources)
    dirs: list[str] = []
    if standalone:  # dir itself is the Application path (no values, no rename)
        if rewrite_kustomization(app_dir, plan):
            plan.root = app_dir
        for k in [plan.main] + plan.extra:
            k.file.unlink(missing_ok=True)
        return
    config = plan.root / "config"
    if app_dir.exists():
        app_dir.rename(config)
        if rewrite_kustomization(config, plan):
            dirs.append("config")
    for k in plan.extra:
        if k.app_dir.exists() and rewrite_kustomization(k.app_dir, plan):
            dirs.append(k.sub)
    write_root_kustomization(plan, dirs)
    for k in [plan.main] + plan.extra:
        k.file.unlink(missing_ok=True)


# ── Application, waves, namespaces ──────────────────────────────────────────

def compute_waves(plans: list[AppPlan], known: dict[str, int]) -> None:
    """wave = 1 + max(wave of deps); deps outside this run come from `known`."""
    by_name = {p.name: p for p in plans}
    memo: dict[str, int] = dict(known)

    def wave(name: str, stack: tuple = ()) -> int:
        if name in memo:
            return memo[name]
        if name in stack:
            raise ValueError(f"dependency cycle: {' -> '.join(stack + (name,))}")
        plan = by_name.get(name)
        deps = plan.deps if plan else set()
        memo[name] = 0 if not deps else 1 + max(wave(d, stack + (name,)) for d in deps)
        return memo[name]

    for p in plans:
        p.wave = wave(p.name)


def existing_waves() -> dict[str, int]:
    """Waves of Applications converted in earlier runs (other namespaces)."""
    out = {}
    for f in (TPL / "argo/apps").rglob("*.yaml.j2"):
        m = re.search(r'sync-wave: "(-?\d+)"', f.read_text())
        if m:
            out[f.name.removesuffix(".yaml.j2")] = int(m.group(1))
    return out


def application(plan: AppPlan) -> str:
    rel = plan.root.relative_to(ROOT / "templates/config").as_posix()
    has_dir = (plan.root / "kustomization.yaml.j2").exists()
    repo = [f'    - repoURL: "{REPO_URL}"', '      targetRevision: "#{ repository_branch }#"']
    if has_dir:
        repo.append(f"      path: {rel}")
    lines = ["---", "apiVersion: argoproj.io/v1alpha1", "kind: Application", "metadata:",
             f"  name: {plan.name}", "  namespace: argo-system", "  annotations:",
             f'    argocd.argoproj.io/sync-wave: "{plan.wave}"', "spec:", "  project: kubernetes",
             "  sources:"] + repo
    if plan.chart:
        c = plan.chart
        lines.append("      ref: repo")
        lines += [f"    - repoURL: {c['repoURL']}", f"      chart: {c['chart']}"]
        if c.get("renovate"):
            lines.append(f"      {c['renovate'].strip()}")
        lines += [f"      targetRevision: {c['version']}", "      helm:",
                  f"        releaseName: {c['releaseName']}", "        valueFiles:",
                  f"          - $repo/{rel}/values.yaml"]
        if (plan.root / "values.sops.yaml.j2").exists():
            lines.append(f"          - $repo/{rel}/values.sops.yaml")
    lines += ["  destination:", "    name: in-cluster",
              f"    namespace: {plan.main.target_ns or plan.namespace}",
              "  syncPolicy:", "    automated:", "      prune: true", "      selfHeal: true",
              "    retry:", "      limit: 5", "      backoff:", "        duration: 10s",
              "        factor: 2", "        maxDuration: 3m", "    syncOptions:",
              "      - ApplyOutOfSyncOnly=true", "      - ServerSideApply=true",
              "      - PruneLast=true", "      - RespectIgnoreDifferences=true"]
    return "\n".join(lines) + "\n"


def rewrite_namespace_kustomization(namespace: str) -> None:
    """Keep namespace.yaml + extra resources; drop ks.yaml entries and the sops component."""
    kfile = APPS / namespace / "kustomization.yaml.j2"
    docs, found = load_docs(kfile)
    kust = docs[0]
    kust["resources"] = CommentedSeq(r for r in kust.get("resources", []) if not r.endswith("ks.yaml"))
    kust.pop("components", None)
    for res in kust["resources"]:
        f = APPS / namespace / f"{res.removeprefix('./')}.j2"
        f = f if f.exists() else APPS / namespace / res.removeprefix("./")
        if f.is_file():
            text = f.read_text()
            text = text.replace("kustomize.toolkit.fluxcd.io/prune: disabled",
                                "argocd.argoproj.io/sync-options: Prune=false")
            f.write_text(flux_text(text))
    kfile.write_text(dump_docs([kust], found))


def write_namespaces_root() -> None:
    """kubernetes/apps/kustomization.yaml listing every converted namespace dir."""
    nss = sorted(p.parent.name for p in APPS.glob("*/kustomization.yaml.j2")
                 if p.parent.name not in SKIP_NAMESPACES
                 and is_converted(p.parent.name))
    (APPS / "kustomization.yaml.j2").write_text(
        "---\n# Namespaces + namespace-wide resources (Application `namespaces`)\n"
        "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n"
        + "".join(f"  - ./{ns}\n" for ns in nss))
    app = TPL / "argo/apps/namespaces.yaml.j2"
    app.parent.mkdir(parents=True, exist_ok=True)
    app.write_text(f"""---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: namespaces
  namespace: argo-system
  annotations:
    argocd.argoproj.io/sync-wave: "-8"
spec:
  project: kubernetes
  source:
    repoURL: "{REPO_URL}"
    targetRevision: "#{{ repository_branch }}#"
    path: kubernetes/apps
  destination:
    name: in-cluster
    namespace: argo-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
      - ServerSideApply=true
      - PruneLast=true
""")


# ── Main ────────────────────────────────────────────────────────────────────

def is_converted(namespace: str) -> bool:
    kust = load_docs(APPS / namespace / "kustomization.yaml.j2")[0][0]
    return not any(r.endswith("ks.yaml") for r in kust.get("resources", []))


def disabled_apps(namespace: str, plans: list[AppPlan]) -> list[str]:
    """App dirs with a ks.yaml that the namespace kustomization does not reference."""
    used = {p.root for p in plans}
    return sorted(d.parent.name for d in (APPS / namespace).glob("*/ks.yaml.j2") if d.parent not in used)


def convert_namespace(namespace: str, plans: list[AppPlan], sources: dict, dry_run: bool) -> None:
    for name in disabled_apps(namespace, plans):
        print(f"{namespace}/{name}: DISABLED in Flux (ks not referenced) - left untouched")
    for p in plans:
        print(f"{namespace}/{p.name}: wave {p.wave}, deps {sorted(p.deps) or '-'}, "
              f"parts {[p.main.sub] + [k.sub for k in p.extra]}")
        if dry_run:
            continue
        try:
            convert_app(p, sources)
        except (ValueError, KeyError) as exc:
            p.notes.append(f"FAILED: {exc}")
        else:
            write_application(p, namespace)
        for n in p.notes:
            print(f"    ! {n}")
    if not dry_run and not any(n.startswith("FAILED") for p in plans for n in p.notes):
        rewrite_namespace_kustomization(namespace)
        shutil.rmtree(RENDERED / "apps" / namespace, ignore_errors=True)


def write_application(p: AppPlan, namespace: str) -> None:
    if not (p.chart or (p.root / "kustomization.yaml.j2").exists()):
        p.notes.append("nothing deployable left - no Application written")
        return
    out = TPL / "argo/apps" / namespace / f"{p.name}.yaml.j2"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(application(p))
    c = p.chart
    print(f"    -> {c['repoURL']}/{c['chart']}:{c['version']}" if c else "    -> kustomize")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--namespace", "-n", action="append", help="namespace(s) to convert (default: all)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    pending = sorted(p.name for p in APPS.iterdir()
                     if p.is_dir() and p.name not in SKIP_NAMESPACES and not is_converted(p.name))
    # waves need the whole dependency graph, even when converting a subset
    plans = {ns: group(ns, discover(ns)) for ns in pending}
    compute_waves([p for ps in plans.values() for p in ps], existing_waves())
    sources = index_chart_sources()
    selected = args.namespace or pending
    for ns in selected:
        if ns not in plans:
            print(f"{ns}: already converted or unknown, skipping")
            continue
        convert_namespace(ns, plans[ns], sources, args.dry_run)
    if not args.dry_run:
        write_namespaces_root()
    return 1 if any(n.startswith("FAILED") for ns in selected for p in plans.get(ns, [])
                    for n in p.notes) else 0


if __name__ == "__main__":
    sys.exit(main())
