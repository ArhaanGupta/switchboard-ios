#!/usr/bin/env python3
"""Copy named screenshot attachments exported by `xcresulttool export attachments`
into docs/screenshots/<name>.png.

Usage: export_screenshots.py <exported-attachments-dir> <output-dir>
"""
import json
import pathlib
import re
import shutil
import sys

src = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)

manifest = json.loads((src / "manifest.json").read_text())
pattern = re.compile(r"^(\d\d-[A-Za-z]+)")
copied = 0
for test in manifest:
    for attachment in test.get("attachments", []):
        human = attachment.get("suggestedHumanReadableName", "")
        match = pattern.match(human)
        if not match:
            continue
        shutil.copy(src / attachment["exportedFileName"], out / f"{match.group(1)}.png")
        copied += 1
        print(f"{human} -> {match.group(1)}.png")

if copied == 0:
    sys.exit("No screenshots found in manifest")
