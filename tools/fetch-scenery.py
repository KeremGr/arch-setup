#!/usr/bin/env python3
"""Fill the wallpaper folders with real scenery photos matched to each scheme's colours.

Usage: fetch-scenery.py SCHEME_DATA_DIR WALLPAPER_DIR WORK_DIR [PER_SCHEME]

Source: Wikimedia Commons *Featured Pictures* (community-reviewed photos), free licences
only (public domain / CC0 / CC BY / CC BY-SA). Each photo is scored against every
scheme/flavour/mode (dominant colours vs. the scheme's primary/secondary/tertiary/surface,
and overall brightness vs. light/dark), then the best fits are downloaded, cropped to
16:9 2560x1440 and saved as WALLPAPER_DIR/<scheme>/<flavour>-<mode>/<photo>.jpg with a
CREDITS.txt (author + licence) next to them.

Downloads land in WORK_DIR (untrusted). No API key, no account, HTTPS only.
"""
import colorsys
import hashlib
import io
import json
import math
import re
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PIL import Image, ImageStat

API = "https://commons.wikimedia.org/w/api.php"
UA = "arch-setup-wallpapers/1.0 (personal desktop wallpaper script)"
OK_LICENCES = re.compile(r"^(public domain|pd|cc0|cc by(-sa)? [1-4]\.0)", re.I)
QUERIES = [
    "mountain landscape", "mountain lake", "alpine valley", "forest", "autumn forest", "autumn landscape",
    "sunset landscape", "sunrise mountains", "twilight landscape", "blue hour", "night sky landscape",
    "milky way", "aurora borealis", "starry sky", "winter landscape snow", "frozen lake", "fog landscape",
    "misty forest", "beach", "coast cliffs", "sea waves", "desert dunes", "canyon", "waterfall", "river valley",
    "meadow flowers", "lavender field", "green hills", "rice terraces", "glacier", "volcano landscape",
    "pink sky", "purple sunset", "moon landscape", "lake reflection", "cherry blossom landscape",
]
# Featured Pictures that match a scenery query but aren't scenery (titles are multilingual).
NOT_SCENERY = re.compile(
    r"lobby|interior|hotel|resort|airport|flughafen|aeroport|station|bahnhof|helicopter|aircraft|airplane"
    r"|bell \d|boeing|airbus|train|locomotive|\bsj\b|rhb|railway|tram|\bbus\b|\bcar\b|bmw|mini\b|truck|ship\b"
    r"|wespe|wasp|bee\b|butterfly|moth|insect|beetle|spider|dragonfly|pareronia|papilio|jellyfish|bird|eagle"
    r"|portrait|berber|people|woman|\bman\b|girl|boy|satellite|satelliidi|iridium|lifebuoy|monument|museum"
    r"|church interior|cathedral|staircase|\bw\d+\b|cropped|restaurant|\blvm\b|\bmgb\b|\biore\b|sncf"
    r"|express|aythya|vanessa|duck|swan|heron|deer|\bfox\b|horse|cattle|Найкращі"
    r"|dampfzug|zug\b|class \d|\bhst\b|\bbm \d|leg.rowing|street corner|facade", re.I)
KEYS = ("primary", "secondary", "tertiary", "surface", "surfaceContainer")


def api(params):
    params = {**params, "format": "json", "formatversion": "2"}
    url = API + "?" + urllib.parse.urlencode(params)
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except Exception:
            time.sleep(2 ** attempt)
    return {}


def get(url, dest):
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    url = url.split("?")[0]     # drop tracking parameters
    if not url.startswith(("https://upload.wikimedia.org/", "https://thumb.wikimedia.org/")):
        return None     # only ever download from Wikimedia's image hosts
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as r:
                dest.write_bytes(r.read())
            return dest
        except Exception:
            time.sleep(2 ** attempt)
    return None


# ---------- colour maths ----------
def lab(rgb):
    def lin(c):
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(float(c)) for c in rgb)
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    f = lambda t: t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    fx, fy, fz = f(x), f(y), f(z)
    return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)


def hexrgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def features(path):
    im = Image.open(path).convert("RGB")
    im.thumbnail((160, 160))
    q = im.quantize(colors=8, method=Image.Quantize.MEDIANCUT)
    pal = q.getpalette()[:24]
    counts = sorted(q.getcolors(), reverse=True)
    total = sum(c for c, _ in counts)
    colours = [(lab(pal[i * 3:i * 3 + 3]), c / total) for c, i in counts]
    grey = im.convert("L")
    mean_l = lab((ImageStat.Stat(grey).mean[0],) * 3)[0]
    return {"colours": colours, "L": mean_l}


def dist(t, colours):
    best = 1e9
    for (L, a, b), share in colours:
        d = math.sqrt((0.5 * (L - t[0])) ** 2 + (a - t[1]) ** 2 + (b - t[2]) ** 2)
        best = min(best, d + 40 * max(0.0, 0.15 - share))
    return best


def score(feat, scheme):
    target_l = 30 if scheme["mode"] == "dark" else 70
    s = 1.0 * dist(scheme["primary"], feat["colours"])
    s += 0.7 * dist(scheme["secondary"], feat["colours"])
    s += 0.7 * dist(scheme["tertiary"], feat["colours"])
    s += 0.6 * dist(scheme["surfaceContainer"], feat["colours"])
    s += 1.5 * abs(feat["L"] - target_l)
    return s


def slug(title):
    s = re.sub(r"^File:", "", title)
    s = re.sub(r"\.[A-Za-z]+$", "", s)
    s = re.sub(r"[^A-Za-z0-9]+", "-", s).strip("-").lower()
    if len(s) < 8:      # non-Latin titles (e.g. Cyrillic) would all collapse to the same name
        s = (s + "-" if s else "photo-") + hashlib.sha1(title.encode()).hexdigest()[:10]
    return s[:60]


def strip_html(s):
    return re.sub(r"<[^>]+>", "", s or "").strip()


def main():
    data, walls, work = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    per = int(sys.argv[4]) if len(sys.argv) > 4 else 4
    thumbs = work / "thumbs"
    thumbs.mkdir(parents=True, exist_ok=True)

    # 1. candidate pool
    pool = {}
    for q in QUERIES:
        res = api({
            "action": "query", "generator": "search", "gsrnamespace": 6, "gsrlimit": 50,
            "gsrsearch": f"incategory:Featured_pictures_on_Wikimedia_Commons {q} filew:>2559 filemime:image/jpeg",
            "prop": "imageinfo", "iiprop": "url|size|extmetadata", "iiurlwidth": 400,
            "iiextmetadatafilter": "LicenseShortName|Artist|LicenseUrl",
        })
        for p in res.get("query", {}).get("pages", []):
            ii = (p.get("imageinfo") or [{}])[0]
            w, h = ii.get("width", 0), ii.get("height", 0)
            meta = ii.get("extmetadata", {})
            lic = strip_html(meta.get("LicenseShortName", {}).get("value"))
            if NOT_SCENERY.search(p["title"]):
                continue
            if not (w >= 2560 and h >= 1440 and 1.45 <= w / h <= 2.0 and OK_LICENCES.match(lic)):
                continue
            pool[p["title"]] = {
                "title": p["title"], "thumb": ii["thumburl"], "orig": ii["url"], "page": ii["descriptionurl"],
                "w": w, "h": h, "licence": lic,
                "licence_url": meta.get("LicenseUrl", {}).get("value", ""),
                "artist": strip_html(meta.get("Artist", {}).get("value")) or "unknown",
            }
        print(f"  {q:<28} pool={len(pool)}", flush=True)

    # 2. colour features from small thumbnails
    def feat(item):
        f = get(item["thumb"], thumbs / (slug(item["title"]) + ".jpg"))
        try:
            item["feat"] = features(f) if f else None
        except Exception:
            item["feat"] = None
    with ThreadPoolExecutor(4) as ex:
        list(ex.map(feat, pool.values()))
    photos = [p for p in pool.values() if p.get("feat")]
    print(f"Scored {len(photos)} photos", flush=True)

    # 3. schemes
    schemes = {}
    for txt in sorted(data.glob("*/*/*.txt")):
        cols = dict(l.split() for l in txt.read_text().splitlines() if len(l.split()) == 2)
        if all(k in cols for k in KEYS):
            key = f"{txt.parent.parent.name}/{txt.parent.name}-{txt.stem}"
            schemes[key] = {k: lab(hexrgb(cols[k])) for k in KEYS} | {"mode": txt.stem}

    # 4. best fits per scheme; a photo is used at most 3 times overall (similar flavours may share)
    used = {}
    plan = {}
    ranked = {k: sorted(photos, key=lambda p, s=s: score(p["feat"], s)) for k, s in schemes.items()}
    if not photos:
        sys.exit("No photos could be scored (network or API change)")
    for k in sorted(schemes, key=lambda k: score(ranked[k][0]["feat"], schemes[k]), reverse=True):
        picks = []
        for p in ranked[k]:
            if used.get(p["title"], 0) < 3:
                picks.append(p)
                used[p["title"]] = used.get(p["title"], 0) + 1
            if len(picks) == per:
                break
        plan[k] = picks

    # 5. download full size (2560px rendition), crop 16:9, save
    full = work / "full"
    full.mkdir(exist_ok=True)

    def fetch_full(p):
        # Wikimedia only serves fixed thumbnail widths; 3840 is the one above 2560.
        url = re.sub(r"/\d+px-", "/3840px-", p["thumb"].split("?")[0]) if p["w"] > 3840 else p["orig"]
        p["full"] = get(url, full / (slug(p["title"]) + ".jpg"))
    needed = {p["title"]: p for picks in plan.values() for p in picks}
    with ThreadPoolExecutor(4) as ex:
        list(ex.map(fetch_full, needed.values()))

    for k, picks in plan.items():
        folder = walls / k
        folder.mkdir(parents=True, exist_ok=True)
        credits = []
        for p in picks:
            if not p.get("full"):
                continue
            im = Image.open(p["full"]).convert("RGB")
            tw = min(im.width, round(im.height * 16 / 9))
            th = round(tw * 9 / 16)
            left, top = (im.width - tw) // 2, (im.height - th) // 2
            im = im.crop((left, top, left + tw, top + th)).resize((2560, 1440), Image.LANCZOS)
            im.save(folder / (slug(p["title"]) + ".jpg"), quality=92, optimize=True)
            credits.append(f"{slug(p['title'])}.jpg\n  {p['title'][5:]}\n  by {p['artist']}\n"
                           f"  {p['licence']} {p['licence_url']}\n  {p['page']}\n")
        (folder / "CREDITS.txt").write_text("Photos from Wikimedia Commons (Featured Pictures).\n\n" + "\n".join(credits))
        print(f"  {k:<28} {len(credits)} photos", flush=True)


if __name__ == "__main__":
    main()
