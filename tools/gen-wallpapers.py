#!/usr/bin/env python3
"""Render original wallpapers for each custom scheme (no downloads, no licences).

Usage: gen-wallpapers.py PALETTES_JSON OUTPUT_DIR [WIDTH HEIGHT]
Writes OUTPUT_DIR/<scheme>/<style>.png
"""
import json
import math
import random
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter


def rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def vgradient(w, h, top, bottom):
    col = Image.new("RGB", (1, 256))
    for y in range(256):
        col.putpixel((0, y), lerp(top, bottom, y / 255))
    return col.resize((w, h), Image.BICUBIC)


def grain(img, amount=10, seed=0):
    random.seed(seed)
    noise = Image.effect_noise(img.size, 64).convert("L")
    noise = Image.merge("RGB", (noise, noise, noise))
    mid = Image.new("RGB", img.size, (128, 128, 128))
    return Image.blend(img, ImageChops.overlay(img, Image.blend(mid, noise, amount / 100)), 1.0)


def style_mesh(w, h, p, rnd):
    img = Image.new("RGB", (w, h), p["surface"])
    blobs = [p["primaryContainer"], p["secondaryContainer"], p["tertiaryContainer"], p["primary"], p["surfaceContainer"]]
    layer = img.copy()
    d = ImageDraw.Draw(layer)
    for i in range(9):
        c = blobs[i % len(blobs)]
        r = rnd.uniform(0.18, 0.42) * w
        x, y = rnd.uniform(-0.1, 1.1) * w, rnd.uniform(-0.1, 1.1) * h
        d.ellipse((x - r, y - r * 0.8, x + r, y + r * 0.8), fill=c)
    layer = layer.filter(ImageFilter.GaussianBlur(w * 0.09))
    return Image.blend(img, layer, 0.85)


def style_hills(w, h, p, rnd):
    dark = sum(p["surface"]) < 384
    img = vgradient(w, h, lerp(p["surfaceContainer"], p["tertiaryContainer"], 0.25), p["surface"])
    sun = p["tertiary"]
    sx, sy, sr = rnd.uniform(0.25, 0.75) * w, h * 0.36, h * 0.085
    glow = Image.new("RGB", (w, h), (0, 0, 0))
    ImageDraw.Draw(glow).ellipse((sx - sr * 3, sy - sr * 3, sx + sr * 3, sy + sr * 3), fill=sun)
    glow = Image.blend(Image.new("RGB", (w, h)), glow.filter(ImageFilter.GaussianBlur(sr * 1.6)), 0.4)
    img = ImageChops.screen(img, glow) if dark else ImageChops.multiply(img, ImageChops.invert(glow))
    d = ImageDraw.Draw(img)
    d.ellipse((sx - sr, sy - sr, sx + sr, sy + sr), fill=lerp(sun, p["onSurface"], 0.1))
    far, mid, near = p["tertiaryContainer"], p["primaryContainer"], p["secondaryContainer"]
    end = lerp(p["surface"], (0, 0, 0) if dark else p["outline"], 0.35)
    layers = 6
    for i in range(layers):
        t = i / (layers - 1)
        col = lerp(far, mid, t * 2) if t < 0.5 else lerp(mid, near, (t - 0.5) * 2)
        col = lerp(col, p["surfaceContainer"], 0.55 * (1 - t))   # atmospheric haze at the back
        col = lerp(col, end, 0.5 * t * t)                          # deepen towards the front
        base = h * (0.5 + 0.085 * i)
        f1, f2, ph = rnd.uniform(1.2, 2.4), rnd.uniform(3, 6), rnd.uniform(0, 6.28)
        amp = h * (0.05 - 0.004 * i)
        pts = [(0, h)]
        for x in range(0, w + 8, 8):
            u = x / w
            pts.append((x, base + amp * math.sin(u * f1 * math.pi + ph) + amp * 0.35 * math.sin(u * f2 * math.pi + ph * 2)))
        pts.append((w, h))
        d.polygon(pts, fill=col)
    return img


def style_peaks(w, h, p, rnd):
    img = vgradient(w, h, lerp(p["surfaceContainer"], p["secondaryContainer"], 0.35), p["surface"])
    d = ImageDraw.Draw(img)
    mx, my, mr = rnd.uniform(0.6, 0.85) * w, h * 0.22, h * 0.06
    d.ellipse((mx - mr, my - mr, mx + mr, my + mr), fill=lerp(p["tertiary"], p["onSurface"], 0.3))
    img = img.filter(ImageFilter.GaussianBlur(1))
    d = ImageDraw.Draw(img)
    layers = 5
    for i in range(layers):
        t = i / (layers - 1)
        col = lerp(lerp(p["outline"], p["primaryContainer"], t), p["surfaceContainer"], 0.6 * (1 - t))
        col = lerp(col, p["surface"], 0.15 + 0.55 * t)
        base = h * (0.55 + 0.1 * i)
        pts, x = [(0, h), (0, base)], 0
        y = base
        while x < w:
            x += rnd.uniform(0.03, 0.09) * w
            y = base - rnd.uniform(0.0, 0.22 - 0.03 * i) * h
            pts.append((x, y))
            x += rnd.uniform(0.03, 0.08) * w
            pts.append((x, base - rnd.uniform(0, 0.05) * h))
        pts.append((w, h))
        d.polygon(pts, fill=col)
        fog = Image.new("RGB", (w, h), p["surfaceContainer"])
        img = Image.blend(img, fog, 0.06)
        d = ImageDraw.Draw(img)
    return img


def style_aurora(w, h, p, rnd):
    dark = sum(p["surface"]) < 384
    if not dark:  # auroras need a dark sky; light schemes get a second soft-mesh instead
        return style_mesh(w, h, p, rnd)
    img = vgradient(w, h, p["surface"], lerp(p["surface"], p["surfaceContainer"], 0.8))
    cols = [p["primary"], p["tertiary"], p["secondary"]] if dark else [p["primaryContainer"], p["tertiaryContainer"], p["secondaryContainer"]]
    acc = Image.new("RGB", (w, h), (0, 0, 0))
    for band in range(3):
        c = cols[band]
        ph, f, yb = rnd.uniform(0, 6.28), rnd.uniform(1.2, 2.2), h * (0.22 + 0.11 * band)
        curtain = Image.new("L", (w, h), 0)
        d = ImageDraw.Draw(curtain)
        for x in range(0, w, 2):
            u = x / w
            y = yb + h * 0.09 * math.sin(u * f * math.pi + ph)
            ln = h * (0.10 + 0.16 * math.sin(u * 5.3 + ph) ** 2)
            for k in range(0, int(ln), 3):  # bright lower edge fading upwards
                a = int(255 * (1 - k / ln) ** 1.6 * (0.6 + 0.4 * math.sin(u * 40 + ph)))
                d.line((x, y - k, x + 1, y - k), fill=a)
        curtain = curtain.filter(ImageFilter.GaussianBlur(w * 0.004))
        acc = ImageChops.add(acc, Image.composite(Image.new("RGB", (w, h), c), Image.new("RGB", (w, h)), curtain))
    if dark:
        img = ImageChops.screen(img, acc)
        d = ImageDraw.Draw(img)
        for _ in range(160):
            x, y = rnd.uniform(0, w), rnd.uniform(0, h * 0.7)
            s = rnd.choice((0.5, 0.7, 1.0))
            d.ellipse((x - s, y - s, x + s, y + s), fill=lerp(p["onSurface"], p["surface"], rnd.uniform(0, 0.6)))
    return img


STYLES = {"mesh": style_mesh, "hills": style_hills, "peaks": style_peaks, "aurora": style_aurora}


def main():
    palettes = json.loads(Path(sys.argv[1]).read_text())
    out = Path(sys.argv[2])
    W, H = (int(sys.argv[3]), int(sys.argv[4])) if len(sys.argv) > 4 else (2560, 1440)
    for name, pal in palettes.items():
        p = {k: rgb(v) for k, v in pal.items() if k != "mode"}
        (out / name).mkdir(parents=True, exist_ok=True)
        if any(f.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp"} for f in (out / name).iterdir()):
            continue    # already has wallpapers (scenery photos or the user's own): only fill empty folders
        for i, (style, fn) in enumerate(STYLES.items()):
            rnd = random.Random(f"{name}-{style}")
            small = fn(W // 2, H // 2, p, rnd)
            img = small.resize((W, H), Image.LANCZOS)
            img = grain(img, 9, seed=i)
            img.save(out / name / f"{style}.png", optimize=True)
            print(f"  {name}/{style}.png")


if __name__ == "__main__":
    main()
