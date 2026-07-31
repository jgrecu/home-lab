#!/usr/bin/env python3
"""
chrome-bookmarks-to-linkding.py

Converts a Chrome bookmarks HTML export into a Linkding-compatible
Netscape HTML file, with folder names added as tags.

Usage:
    python3 chrome-bookmarks-to-linkding.py bookmarks.html > bookmarks-tagged.html

Then in Linkding: Settings → Import → select bookmarks-tagged.html

Folder → tag conversion:
    "Bookmarks bar/Work/Tools" → tags: work, tools
    (Chrome default folders are skipped; spaces become hyphens)

URL blocklist:
    Any bookmark whose URL contains a string in BLOCKED_URL_PATTERNS is dropped.
    Add patterns to the list below — plain substrings, case-insensitive.
"""

import re
import sys
from html import escape
from html.parser import HTMLParser

# Chrome built-in top-level folders — not useful as tags
CHROME_DEFAULT_FOLDERS = {
    "bookmarks bar",
    "other bookmarks",
    "mobile bookmarks",
    "bookmarks",
    "imported",
}

# Bookmarks whose URL contains any of these substrings will be dropped.
# Matching is case-insensitive. Add as many patterns as you need.
BLOCKED_URL_PATTERNS = [
    "wiki.hybris.com",
]


def is_blocked(url: str) -> bool:
    """Return True if the URL matches any entry in BLOCKED_URL_PATTERNS."""
    url_lower = url.lower()
    return any(pattern.lower() in url_lower for pattern in BLOCKED_URL_PATTERNS)


def slugify(text: str) -> str:
    """Convert a folder name to a clean Linkding tag: lowercase, spaces → hyphens."""
    text = text.lower().strip()
    text = re.sub(r"[^\w\s-]", "", text)   # drop non-word chars except hyphens
    text = re.sub(r"[\s_]+", "-", text)     # spaces / underscores → hyphens
    text = re.sub(r"-+", "-", text)         # collapse repeated hyphens
    return text.strip("-")


class BookmarkParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.bookmarks = []
        self._folder_stack = []    # each entry: folder name (str) or None (root level)
        self._pending_folder = None
        self._in_h3 = False
        self._in_a = False
        self._h3_buf = ""
        self._a_buf = ""
        self._a_attrs = {}

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        attrs_dict = {k.lower(): v for k, v in attrs}
        if tag == "dl":
            # The DL following an H3 is that folder's children — push it
            self._folder_stack.append(self._pending_folder)
            self._pending_folder = None
        elif tag == "h3":
            self._in_h3 = True
            self._h3_buf = ""
        elif tag == "a":
            self._in_a = True
            self._a_buf = ""
            self._a_attrs = attrs_dict

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag == "dl":
            if self._folder_stack:
                self._folder_stack.pop()
        elif tag == "h3":
            self._in_h3 = False
            self._pending_folder = self._h3_buf.strip()
        elif tag == "a":
            self._in_a = False
            # Build tag list from current folder path, skip root/Chrome defaults
            folder_tags = [
                slugify(f)
                for f in self._folder_stack
                if f and f.lower() not in CHROME_DEFAULT_FOLDERS and slugify(f)
            ]
            # Preserve any tags that already exist in the source file
            existing_tags = [
                t.strip()
                for t in self._a_attrs.get("tags", "").split(",")
                if t.strip()
            ]
            merged = existing_tags + [t for t in folder_tags if t not in existing_tags]
            self.bookmarks.append({
                "href":     self._a_attrs.get("href", ""),
                "title":    self._a_buf.strip(),
                "add_date": self._a_attrs.get("add_date", ""),
                "tags":     ",".join(merged),
            })

    def handle_data(self, data):
        if self._in_h3:
            self._h3_buf += data
        elif self._in_a:
            self._a_buf += data


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


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 chrome-bookmarks-to-linkding.py <bookmarks.html>", file=sys.stderr)
        print("       Output goes to stdout — redirect to a file:", file=sys.stderr)
        print("       python3 chrome-bookmarks-to-linkding.py bookmarks.html > bookmarks-tagged.html", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]
    try:
        with open(path, encoding="utf-8") as f:
            content = f.read()
    except FileNotFoundError:
        print(f"Error: file not found: {path}", file=sys.stderr)
        sys.exit(1)

    parser = BookmarkParser()
    parser.feed(content)

    all_bookmarks = parser.bookmarks
    kept = [bm for bm in all_bookmarks if not is_blocked(bm["href"])]
    dropped = len(all_bookmarks) - len(kept)

    tagged = sum(1 for bm in kept if bm["tags"])
    untagged = len(kept) - tagged
    print(f"✓ {len(all_bookmarks)} bookmarks parsed — {dropped} blocked, {tagged} kept with tags, {untagged} kept without tags", file=sys.stderr)
    if dropped:
        for bm in all_bookmarks:
            if is_blocked(bm["href"]):
                print(f"  ✗ dropped: {bm['href']}", file=sys.stderr)

    print(render(kept))


if __name__ == "__main__":
    main()
