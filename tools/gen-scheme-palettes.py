#!/usr/bin/env python3
"""Dump every Caelestia scheme/flavour/mode as a palette for gen-wallpapers.py.

Usage: gen-scheme-palettes.py SCHEME_DATA_DIR WALLPAPER_DIR > palettes.json
Keys are "<scheme>/<flavour>-<mode>" (the wallpaper folder the sync script reads).
Combos whose folder already holds images are skipped, so hand-made sets survive.
"""
import json
import sys
from pathlib import Path

KEYS = ("primary", "secondary", "tertiary", "surface", "surfaceContainer", "primaryContainer",
        "secondaryContainer", "tertiaryContainer", "onSurface", "outline")
IMG = {".png", ".jpg", ".jpeg", ".webp"}


def main():
    data, walls = Path(sys.argv[1]), Path(sys.argv[2])
    out = {}
    for txt in sorted(data.glob("*/*/*.txt")):
        mode, flavour, scheme = txt.stem, txt.parent.name, txt.parent.parent.name
        key = f"{scheme}/{flavour}-{mode}"
        folder = walls / key
        if folder.is_dir() and any(p.suffix.lower() in IMG for p in folder.iterdir()):
            continue
        cols = dict(line.split() for line in txt.read_text().splitlines() if len(line.split()) == 2)
        if all(k in cols for k in KEYS):
            out[key] = {k: cols[k] for k in KEYS} | {"mode": mode}
    json.dump(out, sys.stdout, indent=1)


if __name__ == "__main__":
    main()
