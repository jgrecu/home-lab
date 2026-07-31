#!/usr/bin/env python3
"""
check-dead-links.py

Reads a Netscape HTML bookmarks file, checks each URL concurrently,
and outputs a cleaned file with dead links removed.

Usage:
    # Standalone
    python3 check-dead-links.py bookmarks-tagged.html > bookmarks-clean.html

    # Chained with the tagging script
    python3 chrome-bookmarks-to-linkding.py bookmarks.html \\
      | python3 check-dead-links.py > bookmarks-clean.html

Options (set via environment variables or edit the CONFIG block below):
    TIMEOUT   Seconds to wait per request  (default: 10)
    WORKERS   Concurrent workers           (default: 20)

Exit codes:
    0  success
    1  usage / file error
"""

import os
import re
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from html import escape
from html.parser import HTMLParser
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

# ── Configuration ─────────────────────────────────────────────────────────────

TIMEOUT = int(os.getenv("TIMEOUT", "10"))   # seconds per request
WORKERS = int(os.getenv("WORKERS", "20"))   # concurrent workers

# Mimic a real browser — some sites block Python's default user-agent
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)

# HTTP status codes that mean the link is definitively dead
DEAD_STATUSES = {404, 410, 451}

# HTTP status codes we treat as alive even though they look like errors
# (auth-protected, rate-limited, or bot-blocked pages are likely still alive)
ALIVE_STATUSES = {401, 403, 405, 406, 429, 503}

# ── Netscape HTML parser ───────────────────────────────────────────────────────

class BookmarkParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.bookmarks = []
        self._in_a = False
        self._a_buf = ""
        self._a_attrs = {}

    def handle_starttag(self, tag, attrs):
        if tag.lower() == "a":
            self._in_a = True
            self._a_buf = ""
            self._a_attrs = {k.lower(): v for k, v in attrs}

    def handle_endtag(self, tag):
        if tag.lower() == "a":
            self._in_a = False
            self.bookmarks.append({
                "href":     self._a_attrs.get("href", ""),
                "title":    self._a_buf.strip(),
                "add_date": self._a_attrs.get("add_date", ""),
                "tags":     self._a_attrs.get("tags", ""),
            })

    def handle_data(self, data):
        if self._in_a:
            self._a_buf += data


# ── URL checking ──────────────────────────────────────────────────────────────

def check_url(url: str) -> tuple[str, str, str]:
    """
    Check a single URL. Returns (url, status, detail).
    status is one of: 'alive', 'dead', 'skip'
    """
    if not url.startswith(("http://", "https://")):
        return url, "skip", "non-http scheme"

    headers = {"User-Agent": USER_AGENT}

    def _request(method: str) -> tuple[str, str]:
        req = Request(url, method=method, headers=headers)
        try:
            with urlopen(req, timeout=TIMEOUT) as resp:
                code = resp.status
                if code in DEAD_STATUSES:
                    return "dead", f"HTTP {code}"
                return "alive", f"HTTP {code}"
        except HTTPError as e:
            if e.code in DEAD_STATUSES:
                return "dead", f"HTTP {e.code}"
            if e.code in ALIVE_STATUSES:
                return "alive", f"HTTP {e.code} (auth/rate-limit — keeping)"
            return "dead", f"HTTP {e.code}"
        except TimeoutError:
            return "dead", "timeout"
        except URLError as e:
            return "dead", f"connection error: {e.reason}"
        except Exception as e:          # noqa: BLE001
            return "dead", f"error: {e}"

    # Try HEAD first (no body download), fall back to GET if server rejects HEAD
    status, detail = _request("HEAD")
    if status == "dead" and "HTTP 405" not in detail and "HTTP 4" not in detail:
        # HEAD might be blocked — retry with GET
        status, detail = _request("GET")

    return url, status, detail


# ── Netscape HTML renderer ────────────────────────────────────────────────────

def render(bookmarks: list) -> str:
    lines = [
        "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
        '<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">',
        "<TITLE>Bookmarks</TITLE>",
        "<H1>Bookmarks</H1>",
        "<DL><p>",
    ]
    for bm in bookmarks:
        parts = f'HREF="{escape(bm["href"])}"'
        if bm["add_date"]:
            parts += f' ADD_DATE="{bm["add_date"]}"'
        if bm["tags"]:
            parts += f' TAGS="{escape(bm["tags"])}"'
        lines.append(f'<DT><A {parts}>{escape(bm["title"])}</A>')
    lines.append("</DL>")
    return "\n".join(lines)


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) >= 2:
        path = sys.argv[1]
        try:
            with open(path, encoding="utf-8") as f:
                content = f.read()
        except FileNotFoundError:
            print(f"Error: file not found: {path}", file=sys.stderr)
            sys.exit(1)
    else:
        content = sys.stdin.read()

    parser = BookmarkParser()
    parser.feed(content)
    bookmarks = parser.bookmarks

    total = len(bookmarks)
    print(f"Checking {total} URLs ({WORKERS} workers, {TIMEOUT}s timeout) …", file=sys.stderr)

    # Check all URLs concurrently
    results: dict[str, tuple[str, str]] = {}
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = {pool.submit(check_url, bm["href"]): bm["href"] for bm in bookmarks}
        done = 0
        for future in as_completed(futures):
            url, status, detail = future.result()
            results[url] = (status, detail)
            done += 1
            if done % 100 == 0 or done == total:
                print(f"  {done}/{total} checked …", file=sys.stderr)

    # Partition into kept / dropped / skipped
    kept, dead, skipped = [], [], []
    for bm in bookmarks:
        status, detail = results.get(bm["href"], ("skip", "no result"))
        if status == "alive":
            kept.append(bm)
        elif status == "skip":
            kept.append(bm)   # keep non-http bookmarks (e.g. file://)
            skipped.append((bm["href"], detail))
        else:
            dead.append((bm["href"], bm["title"], detail))

    # Report
    print(f"\n── Results ──────────────────────────────────────────", file=sys.stderr)
    print(f"  ✓ kept:    {len(kept)}", file=sys.stderr)
    print(f"  ✗ dead:    {len(dead)}", file=sys.stderr)
    print(f"  ~ skipped: {len(skipped)} (non-http)", file=sys.stderr)

    if dead:
        print(f"\n── Dead links ───────────────────────────────────────", file=sys.stderr)
        for url, title, detail in sorted(dead, key=lambda x: x[2]):
            print(f"  [{detail}]  {title}  →  {url}", file=sys.stderr)

    print(render(kept))


if __name__ == "__main__":
    main()
