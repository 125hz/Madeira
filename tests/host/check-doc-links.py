#!/usr/bin/env python3
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


link_pat = re.compile(r'\[([^\]]+)\]\(([^)]+)\)')

# Only check tracked Madeira files to avoid submodule directories (FEX/, etc.)
res = subprocess.run(['git', 'ls-files', '*.md'], cwd=root, capture_output=True, text=True)
if res.returncode == 0 and res.stdout.strip():
    md_files = sorted([root / p for p in res.stdout.splitlines() if p.strip()])
else:
    md_files = sorted(root.glob('docs/*.md')) + [root / 'README.md', root / 'CONTRIBUTING.md']

check("repo has markdown documentation", len(md_files) > 0)

broken_links = []
total_links = 0

for md_file in md_files:
    if not md_file.exists():
        continue
    text = md_file.read_text(encoding='utf-8', errors='ignore')
    for m in link_pat.finditer(text):
        target = m.group(2).strip()
        if target.startswith(('http://', 'https://', 'mailto:', '#')):
            continue
        total_links += 1
        file_part = target.split('#')[0]
        if not file_part:
            continue
        target_path = (md_file.parent / file_part).resolve()
        if not target_path.exists():
            broken_links.append((md_file.relative_to(root), target))

check("all internal doc links resolve", len(broken_links) == 0)
if broken_links:
    for src, dst in broken_links:
        print("  broken: %s -> %s" % (src, dst))

sys.exit(0 if ok else 1)
