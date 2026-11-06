#!/usr/bin/env python3
"""Generate custom Caelestia colour schemes from hand-picked palettes.

Each scheme defines anchor colours for the Material 3 palettes. Caelestia's own
generator then derives every role (surfaces, containers, terminal colours,
named accents) so the result is a complete, consistent scheme that every
themed app understands.

Usage: gen-schemes.py OUTPUT_DIR
Writes OUTPUT_DIR/<scheme>/default/{dark,light}.txt and OUTPUT_DIR/palettes.json
"""
import json
import sys
from pathlib import Path

from materialyoucolor.hct import Hct
from materialyoucolor.palettes.tonal_palette import TonalPalette
from materialyoucolor.scheme.scheme_tonal_spot import SchemeTonalSpot

import caelestia.utils.material.generator as gen

# name: anchors (hex without #). neutral = tint for backgrounds/surfaces.
SCHEMES = {
    "autumn-forest": {  # copper, moss, amber
        "primary": "B87333", "secondary": "6E7F45", "tertiary": "E0A526",
        "neutral": "5A4636", "neutral_chroma": 10, "default_mode": "dark",
    },
    "nocturne": {  # burgundy, wine, antique gold
        "primary": "9B1B30", "secondary": "722F37", "tertiary": "C5A253",
        "neutral": "3B1F27", "neutral_chroma": 9, "default_mode": "dark",
    },
    "cream": {  # cream, caramel, sage
        "primary": "B08A5A", "secondary": "9C8B73", "tertiary": "8A9A7B",
        "neutral": "EFE6D2", "neutral_chroma": 7, "default_mode": "light",
    },
}


def hct(hexstr: str) -> Hct:
    return Hct.from_int(int(f"FF{hexstr}", 16))


def make_constructor(spec: dict):
    def construct(source_color_hct, is_dark, contrast_level):
        s = SchemeTonalSpot(source_color_hct=hct(spec["primary"]), is_dark=is_dark, contrast_level=contrast_level)
        p, sec, ter, n = (hct(spec[k]) for k in ("primary", "secondary", "tertiary", "neutral"))
        s.primary_palette = TonalPalette.from_hue_and_chroma(p.hue, max(p.chroma, 36))
        s.secondary_palette = TonalPalette.from_hue_and_chroma(sec.hue, max(sec.chroma, 20))
        s.tertiary_palette = TonalPalette.from_hue_and_chroma(ter.hue, max(ter.chroma, 32))
        s.neutral_palette = TonalPalette.from_hue_and_chroma(n.hue, spec["neutral_chroma"])
        s.neutral_variant_palette = TonalPalette.from_hue_and_chroma(n.hue, spec["neutral_chroma"] + 6)
        return s
    return construct


class _S:  # minimal stand-in for caelestia's Scheme object
    def __init__(self, mode):
        self.mode, self.variant, self.flavour = mode, "custom", "default"


def main(out: Path) -> None:
    real_get_scheme = gen.get_scheme
    meta = {}
    for name, spec in SCHEMES.items():
        gen.get_scheme = lambda _v, spec=spec: make_constructor(spec)
        for mode in ("dark", "light"):
            colours = gen.gen_scheme(_S(mode), hct(spec["primary"]))
            d = out / name / "default"
            d.mkdir(parents=True, exist_ok=True)
            (d / f"{mode}.txt").write_text("".join(f"{k} {v}\n" for k, v in colours.items()))
            if mode == spec["default_mode"]:
                meta[name] = {k: colours[k] for k in (
                    "primary", "secondary", "tertiary", "surface", "surfaceContainer",
                    "primaryContainer", "secondaryContainer", "tertiaryContainer", "onSurface", "outline")}
                meta[name]["mode"] = mode
    gen.get_scheme = real_get_scheme
    (out / "palettes.json").write_text(json.dumps(meta, indent=2))
    print(f"Generated {len(SCHEMES)} schemes in {out}")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
