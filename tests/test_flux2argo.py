"""Unit tests for scripts/flux2argo.py (pure functions: values split, chart mapping, waves)."""
import importlib.util
import io
import sys
from pathlib import Path

import pytest
from ruamel.yaml import YAML

SPEC = importlib.util.spec_from_file_location(
    "flux2argo", Path(__file__).resolve().parent.parent / "scripts/flux2argo.py")
flux2argo = importlib.util.module_from_spec(SPEC)
sys.modules["flux2argo"] = flux2argo
SPEC.loader.exec_module(flux2argo)

APP_TEMPLATE_HR = """
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: radarr
spec:
  chartRef: {kind: OCIRepository, name: radarr}
  values:
    controllers:
      radarr:
        containers:
          app:
            image:
              repository: lscr.io/linuxserver/radarr
              # renovate: datasource=docker depName=lscr.io/linuxserver/radarr
              tag: 6.4.4
            env:
              TZ: Europe/Madrid
              PUBLIC_URL: https://radarr.${SECRET_DOMAIN}
    service:
      app:
        ports:
          http: {port: &port 7878}
    route:
      app:
        annotations:
          gethomepage.dev/href: https://radarr.${SECRET_DOMAIN}
          gethomepage.dev/name: Radarr
        hostnames: ["radarr.${SECRET_DOMAIN}"]
        rules:
          - backendRefs: [{identifier: app, port: *port}]
"""

HELMREPO_HR = """
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: longhorn
spec:
  chart:
    spec:
      chart: longhorn
      version: 1.13.0
      sourceRef: {kind: HelmRepository, name: longhorn}
  values:
    defaultSettings: {defaultReplicaCount: 2}
"""


def load_hr(text: str):
    text = text.replace(flux2argo.DOMAIN_VAR, flux2argo.DOMAIN_TOKEN)
    return flux2argo.yaml_rt().load(text)


def dump(node) -> str:
    buf = io.StringIO()
    flux2argo.yaml_rt().dump(node, buf)
    return buf.getvalue()


def test_cut_point_stops_before_first_list_index():
    assert flux2argo.cut_point(("route", "app", "hostnames", 0)) == ("route", "app", "hostnames")
    assert flux2argo.cut_point(("a", "b", "c")) == ("a", "b", "c")
    assert flux2argo.cut_point(("env", 0, "value")) == ("env",)


def test_split_moves_only_domain_keys_and_keeps_image_tag_plain():
    hr = load_hr(APP_TEMPLATE_HR)
    plain, secret = flux2argo.split_values(hr["spec"]["values"])
    plain_txt, secret_txt = dump(plain), dump(secret)
    assert flux2argo.DOMAIN_TOKEN not in plain_txt
    assert "tag: 6.4.4" in plain_txt and "renovate:" in plain_txt
    assert "TZ: Europe/Madrid" in plain_txt
    assert "gethomepage.dev/name: Radarr" in plain_txt
    s = YAML(typ="safe").load(secret_txt)
    assert s["route"]["app"]["hostnames"] == ["radarr.__DOMAIN__"]
    assert s["route"]["app"]["annotations"] == {"gethomepage.dev/href": "https://radarr.__DOMAIN__"}
    assert s["controllers"]["radarr"]["containers"]["app"]["env"] == {"PUBLIC_URL": "https://radarr.__DOMAIN__"}
    assert "rules" not in s["route"]["app"]  # non-domain siblings stay plain


def test_split_files_are_valid_yaml_even_with_cross_file_anchor():
    hr = load_hr(APP_TEMPLATE_HR)
    plain, secret = flux2argo.split_values(hr["spec"]["values"])
    merged = YAML(typ="safe").load(dump(plain))
    assert merged["route"]["app"]["rules"][0]["backendRefs"][0]["port"] == 7878
    assert YAML(typ="safe").load(dump(secret))["route"]


def test_split_without_domain_returns_empty_secret():
    hr = load_hr(HELMREPO_HR)
    plain, secret = flux2argo.split_values(hr["spec"]["values"])
    assert not secret and plain["defaultSettings"]["defaultReplicaCount"] == 2


def test_chart_from_oci_repository():
    hr = load_hr(APP_TEMPLATE_HR)
    sources = {"radarr": {"kind": "OCIRepository", "url": "oci://ghcr.io/bjw-s-labs/helm/app-template",
                          "tag": "5.3.0", "type": "default", "renovate": "# renovate: x"}}
    c = flux2argo.chart_from_helmrelease(hr, sources)
    assert (c["repoURL"], c["chart"], c["version"]) == ("ghcr.io/bjw-s-labs/helm", "app-template", "5.3.0")


@pytest.mark.parametrize("url,type_,expected", [
    ("https://charts.longhorn.io", "default", "https://charts.longhorn.io"),
    ("oci://code.forgejo.org/forgejo-helm/", "oci", "code.forgejo.org/forgejo-helm"),
])
def test_chart_from_helm_repository(url, type_, expected):
    hr = load_hr(HELMREPO_HR)
    sources = {"longhorn": {"kind": "HelmRepository", "url": url, "tag": "", "type": type_, "renovate": None}}
    c = flux2argo.chart_from_helmrelease(hr, sources)
    assert (c["repoURL"], c["chart"], c["version"]) == (expected, "longhorn", "1.13.0")


def make_plan(name, deps):
    ks = flux2argo.Ks(name, f"./kubernetes/apps/ns/{name}/app", deps, "ns", Path("x"))
    return flux2argo.AppPlan(name, "ns", Path("x"), ks)


def test_waves_follow_longest_chain_and_known_waves():
    plans = [make_plan("longhorn", []), make_plan("seaweedfs", ["longhorn"]),
             make_plan("cnpg", ["longhorn", "seaweedfs"]), make_plan("app", ["cnpg", "external"])]
    flux2argo.compute_waves(plans, {"external": 5})
    assert [p.wave for p in plans] == [0, 1, 2, 6]


def test_waves_detect_cycles():
    with pytest.raises(ValueError, match="cycle"):
        flux2argo.compute_waves([make_plan("a", ["b"]), make_plan("b", ["a"])], {})


def test_protect_and_restore_roundtrip_jinja():
    text = 'addr: "#{ cluster_pod_cidr }#"\nhost: x.${SECRET_DOMAIN}\n'
    safe, found = flux2argo.protect(text)
    assert "#{" not in safe
    assert flux2argo.restore(safe.replace(flux2argo.DOMAIN_VAR, flux2argo.DOMAIN_TOKEN), found) == \
        'addr: "#{ cluster_pod_cidr }#"\nhost: x.#{ cloudflare_domain }#\n'


def test_block_tags_survive_and_move_to_column_zero():
    text = "a:\n  b: 1\n  #% if x %#\n  c: 2\n  #% endif %#\n"
    safe, found = flux2argo.protect(text)
    data = flux2argo.yaml_rt().load(safe)
    out = flux2argo.restore(dump(data), found)
    assert "\n#% if x %#\n" in out and "\n#% endif %#\n" in out and "c: 2" in out


def test_file_guard_detects_whole_file_condition():
    assert flux2argo.file_guard("#% if a %#\n---\nx: 1\n#% endif %#\n") == ("#% if a %#", "#% endif %#")
    assert flux2argo.file_guard("---\nx: 1\n") is None


def test_flux_pattern_substitution_becomes_jinja_replace():
    assert flux2argo.flux_text("n: ${SECRET_DOMAIN/./-}-tls") == \
        "n: #{ cloudflare_domain | replace('.', '-', 1) }#-tls"
    assert flux2argo.flux_text("h: a.${SECRET_DOMAIN} x: $${v}") == "h: a.#{ cloudflare_domain }# x: ${v}"


def test_domain_in_jinja_placeholders_and_comments_never_stays_plain():
    raw = "a:\n  # see https://x.${SECRET_DOMAIN}\n  host: x.${SECRET_DOMAIN}\n  name: ${SECRET_DOMAIN/./-}\n  keep: 1\n"
    text, found = flux2argo.protect(flux2argo.flux_text(raw))
    plain, secret = flux2argo.split_values(flux2argo.yaml_rt().load(text), found)
    out = flux2argo.scrub_comments(flux2argo.dump_values(plain, found, ""))
    assert "cloudflare_domain" not in out and "keep: 1" in out
    assert set(secret["a"]) == {"host", "name"}


def test_jinja_preamble_is_collected():
    raw = "---\n#% set xs = [] %#\n#% for n in nodes %#\n#% endfor %#\napiVersion: v1\n"
    assert flux2argo.jinja_preamble(raw) == "#% set xs = [] %#\n#% for n in nodes %#\n#% endfor %#\n"
    assert flux2argo.jinja_preamble("---\napiVersion: v1\n") == ""


def test_comments_after_block_scalar_are_dropped_not_absorbed():
    raw = "a:\n  conf: |\n    [X]\n      k v\n\n  # prose about b\n  b: 1\n"
    out = flux2argo.drop_comments_after_block_scalars(raw)
    assert "prose" not in out and "b: 1" in out and "[X]" in out
    data = flux2argo.yaml_rt().load(out)
    assert data["a"]["conf"] == "[X]\n  k v\n"


def test_verify_split_detects_changed_values():
    hr = load_hr(APP_TEMPLATE_HR)
    expected = YAML(typ="safe").load(APP_TEMPLATE_HR.replace(flux2argo.DOMAIN_VAR, flux2argo.DOMAIN_TOKEN))
    plain, secret = flux2argo.split_values(hr["spec"]["values"])
    flux2argo.verify_split(expected["spec"]["values"], plain, secret, [])
    plain["service"]["app"]["ports"]["http"]["port"] = 1
    with pytest.raises(ValueError, match="semantic"):
        flux2argo.verify_split(expected["spec"]["values"], plain, secret, [])
