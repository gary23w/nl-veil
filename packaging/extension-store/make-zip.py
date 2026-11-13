"""Build the store upload zip from extension/ (manifest.json at the zip root). Run from the repo root:
    python packaging/extension-store/make-zip.py
"""
import json
import os
import zipfile

SRC = "extension"
manifest = json.load(open(os.path.join(SRC, "manifest.json"), encoding="utf-8"))
out = os.path.join("packaging", "extension-store", f"nl-veil-browser-link-{manifest['version']}.zip")

files = []
for root, _, names in os.walk(SRC):
    for n in names:
        files.append(os.path.relpath(os.path.join(root, n), SRC).replace(os.sep, "/"))

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for rel in sorted(files):
        info = zipfile.ZipInfo(rel, date_time=(2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        z.writestr(info, open(os.path.join(SRC, rel), "rb").read())
print(out)
for rel in sorted(files):
    print("  " + rel)
