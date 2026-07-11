#!/usr/bin/env python3
"""Check external Markdown links with retries for scheduled CI."""

from __future__ import annotations

import re
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
URL_RE = re.compile(r"https://[^)\s]+")


def main() -> int:
    urls: set[str] = set()
    paths = [
        ROOT / "README.md",
        *ROOT.glob("litellm-*/**/*.md"),
        *ROOT.glob("docs/**/*.md"),
        *ROOT.glob("curriculum/**/*.md"),
        *ROOT.glob("examples/**/*.md"),
    ]
    for path in paths:
        for url in URL_RE.findall(path.read_text(encoding="utf-8")):
            cleaned = url.rstrip('`\'".,;:')
            hostname = urlparse(cleaned).hostname or ""
            if hostname in {"example.com", "litellm.example.com"} or any(
                marker in cleaned for marker in ("<", ">", "${", "your-resource")
            ):
                continue
            urls.add(cleaned)

    failures: list[str] = []
    for url in sorted(urls):
        request = urllib.request.Request(url, headers={"User-Agent": "litellm-skills-link-check/1.0"})
        for attempt in range(2):
            try:
                with urllib.request.urlopen(request, timeout=20) as response:
                    if response.status < 400:
                        break
            except (urllib.error.URLError, TimeoutError) as exc:
                if attempt == 1:
                    failures.append(f"{url}: {exc}")
                else:
                    time.sleep(1)
        else:
            continue

    if failures:
        print("外部連結檢查失敗：", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print(f"外部連結檢查通過：{len(urls)} 個連結")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
