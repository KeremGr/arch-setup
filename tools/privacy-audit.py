#!/usr/bin/env python3
"""Personal-information audit for this repo (runs alongside Gitleaks, not instead of it).

Gitleaks finds secrets (keys, tokens). This finds things that identify YOU or YOUR machine
(and traces of AI tools):
usernames, home paths, hostnames, emails, IP/MAC addresses, UUIDs, machine-id, disk / monitor /
GPU / CPU models and serials, Wi-Fi names, and any extra terms you list privately.

Identifiers are read live from this machine at scan time and kept in memory only. They are
never written to the repo, and matches are printed masked.

Usage:
  privacy-audit.py                 files that would be committed (tracked + untracked, not ignored)
  privacy-audit.py --staged        only what is staged for the next commit
  privacy-audit.py --history       every blob + every commit's author/committer/message, all refs
  privacy-audit.py --all           all of the above

Extra private terms (one per line, e.g. your real name, other emails), kept OUTSIDE the repo:
  ~/.config/arch-setup/private-terms.txt
Intentional public values (e.g. Cloudflare DNS IPs) are allow-listed in .privacy-allow (regex per line).
Exit code: 0 clean, 1 findings, 2 error.
"""
import ipaddress
import json
import os
import re
import socket
import subprocess
import sys
from pathlib import Path

REPO = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                           check=True).stdout.strip())
HOME = Path.home()
PRIVATE_TERMS = Path(os.getenv("XDG_CONFIG_HOME", HOME / ".config")) / "arch-setup/private-terms.txt"
ALLOW_FILE = REPO / ".privacy-allow"
MAX_BYTES = 2_000_000


def sh(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def git(*args, binary=False):
    r = subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, check=True)
    return r.stdout if binary else r.stdout.decode("utf-8", "replace")


# ---------------------------------------------------------------- live identifiers
def live_terms():
    """{term: category} gathered from this machine. Short/generic values are skipped."""
    t = {}

    def add(val, cat, minlen=4):
        val = (val or "").strip()
        if len(val) >= minlen and val.lower() not in {"none", "unknown", "default", "n/a", "to be filled by o.e.m."}:
            t[val] = cat

    add(os.getenv("USER") or HOME.name, "username", 3)
    add(str(HOME), "home path")
    add(socket.gethostname(), "hostname", 3)
    add(Path("/etc/hostname").read_text() if Path("/etc/hostname").exists() else "", "hostname", 3)
    add(Path("/etc/machine-id").read_text() if Path("/etc/machine-id").exists() else "", "machine-id")
    for line in sh("git", "config", "--global", "--get-regexp", r"user\.(name|email)").splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and "noreply" not in parts[1]:
            add(parts[1], "git identity")
    # disks: UUIDs, serials, models, WWNs, labels
    try:
        for dev in json.loads(sh("lsblk", "-J", "-o", "UUID,PARTUUID,SERIAL,MODEL,WWN,PTUUID")).get("blockdevices", []):
            stack = [dev]
            while stack:
                d = stack.pop()
                stack += d.get("children") or []
                for k, cat in (("uuid", "disk UUID"), ("partuuid", "partition UUID"), ("ptuuid", "partition table UUID"),
                               ("serial", "disk serial"), ("model", "disk model"), ("wwn", "disk WWN")):
                    add(d.get(k), cat)
    except ValueError:
        pass
    # disk hardware IDs as the kernel names them (model_serial), plus each part on its own
    for link in Path("/dev/disk/by-id").glob("*"):
        name = re.sub(r"-part\d+$", "", link.name)
        add(name, "disk hardware ID")
        for part in re.split(r"[-_]", name.split("-", 1)[-1]):
            if len(part) >= 6 and re.search(r"\d", part) and re.search(r"[A-Za-z]", part):
                add(part, "disk hardware ID")
    # network: MACs, local addresses, saved Wi-Fi / connection names
    for nic in Path("/sys/class/net").glob("*/address"):
        mac = nic.read_text().strip()
        if mac and set(mac) != {"0", ":"}:
            add(mac, "MAC address")
    for m in re.finditer(r"inet6? ([0-9a-fA-F:.]+)/", sh("ip", "-o", "addr")):
        ip = ipaddress.ip_address(m.group(1))
        if not ip.is_loopback:
            add(str(ip), "local IP")
    for name in sh("nmcli", "-t", "-f", "NAME,TYPE", "connection", "show").splitlines():
        n, _, typ = name.rpartition(":")
        if "wireless" in typ:
            add(n, "Wi-Fi name")
    # monitors (make/model/serial/description) and GPU/CPU model strings
    try:
        for mon in json.loads(sh("hyprctl", "monitors", "all", "-j") or "[]"):
            for k in ("make", "model", "serial"):
                add(mon.get(k), f"monitor {k}")
    except ValueError:
        pass
    for line in sh("nvidia-smi", "--query-gpu=name,serial,uuid", "--format=csv,noheader").splitlines():
        for i, part in enumerate(p.strip() for p in line.split(",")):
            add(part, ("GPU model", "GPU serial", "GPU UUID")[i] if i < 3 else "GPU")
            if i == 0:  # also the short model number form
                m = re.search(r"\d{4}( Ti| SUPER)?", part)
                add(m and m.group(0), "GPU model")
    cpu = re.search(r"model name\s*:\s*(.+)", Path("/proc/cpuinfo").read_text())
    if cpu:
        add(cpu.group(1), "CPU model")
        m = re.search(r"i\d-\d{4,5}\w*|Ryzen \d \d{4}\w*", cpu.group(1))
        add(m and m.group(0), "CPU model")
        m = re.search(r"\d{4,5}[A-Z]{1,2}\b", cpu.group(1))
        add(m and m.group(0), "CPU model")
    # timezone and its city
    tz = os.path.realpath("/etc/localtime").split("zoneinfo/")[-1]
    if "/" in tz:
        add(tz, "timezone")
        add(tz.split("/")[-1].replace("_", " "), "city (timezone)")
    if PRIVATE_TERMS.exists():
        for line in PRIVATE_TERMS.read_text().splitlines():
            if line.strip() and not line.startswith("#"):
                add(line, "private term", 2)
    return t


GENERIC = [
    ("email", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.(?!(?:service|target|timer|socket|mount|path|device|slice|scope|swap)\b)[A-Za-z]{2,}\b")),
    ("home path", re.compile(r"/home/[A-Za-z0-9][A-Za-z0-9._-]*")),
    ("UUID", re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")),
    ("MAC address", re.compile(r"\b[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}\b")),
    ("IPv4", re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")),
    ("IPv6", re.compile(r"\b(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}\b")),
    ("GRUB password hash", re.compile(r"grub\.pbkdf2\.sha512\.\d+\.[0-9A-F]+")),
    ("LUKS recovery key", re.compile(r"\b[cbdefghijklnrtuv]{8}(?:-[cbdefghijklnrtuv]{8}){7}\b")),
    ("private key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("GitHub token", re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}")),
    ("shadow hash", re.compile(r"\$(?:y|6|5|2[aby]|argon2id?)\$[^\s:\"']{20,}")),    # Traces of AI tools in code, comments or commit messages (words split so this file passes itself)
    ("AI trace", re.compile(r"\b(?:" + "|".join(["clau" + "de", "anthro" + "pic", "co-authored" + "-by", "chat" + "gpt",
                                                  "open" + "ai", "co" + "pilot", "generated (?:by|with) (?:an? )?a" + "i"]) + r")\b", re.I)),
]
# Public values that are fine to publish (documentation ranges, loopback, wildcard).
SAFE_IPS = {"0.0.0.0", "127.0.0.1", "255.255.255.255"}


def allow_patterns():
    pats = [re.compile(r"users\.noreply\.github\.com$", re.I), re.compile(r"@(example\.(com|org)|localhost)$", re.I)]
    if ALLOW_FILE.exists():
        for line in ALLOW_FILE.read_text().splitlines():
            if line.strip() and not line.startswith("#"):
                pats.append(re.compile(line.strip()))
    return pats


def mask(s):
    return s if len(s) <= 4 else s[:2] + "*" * (len(s) - 4) + s[-2:]


class Scanner:
    def __init__(self):
        self.terms = live_terms()
        self.term_re = re.compile("|".join(re.escape(k) for k in sorted(self.terms, key=len, reverse=True)), re.I) \
            if self.terms else None
        self.allow = allow_patterns()
        self.findings = []

    def allowed(self, value):
        return any(p.search(value) for p in self.allow)

    def scan_text(self, where, text):
        for n, line in enumerate(text.splitlines(), 1):
            hits = []
            if self.term_re:
                for m in self.term_re.finditer(line):
                    cat = next((c for k, c in self.terms.items() if k.lower() == m.group(0).lower()), "identifier")
                    hits.append((cat, m.group(0)))
            for cat, rx in GENERIC:
                for m in rx.finditer(line):
                    v = m.group(0)
                    if cat == "IPv4":
                        try:
                            ip = ipaddress.ip_address(v)
                        except ValueError:
                            continue
                        if v in SAFE_IPS or ip.is_loopback:
                            continue
                    if cat == "IPv6":
                        try:
                            ipaddress.ip_address(v)
                        except ValueError:
                            continue     # e.g. clock times, hex ids: not an address
                    hits.append((cat, v))
            for cat, v in hits:
                if not self.allowed(v):
                    self.findings.append((where, n, cat, v))

    def scan_blob(self, where, data):
        if len(data) > MAX_BYTES:
            self.findings.append((where, 0, "too large to scan (review by hand)", ""))
            return
        if b"\0" in data[:8000]:
            self.findings.append((where, 0, "binary file (may hide metadata, review by hand)", ""))
            return
        self.scan_text(where, data.decode("utf-8", "replace"))
        self.scan_text(where + " [path]", where)

    # -------- modes
    def worktree(self):
        files = git("ls-files", "-z", "--cached", "--others", "--exclude-standard").split("\0")
        for f in filter(None, files):
            p = REPO / f
            if p.is_file():
                self.scan_blob(f, p.read_bytes())

    def staged(self):
        for f in filter(None, git("diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR").split("\0")):
            self.scan_blob(f"(staged) {f}", git("show", f":{f}", binary=True))

    def history(self):
        if not git("rev-list", "--all").strip():
            return
        seen = set()
        for line in git("rev-list", "--all", "--objects").splitlines():
            sha, _, path = line.partition(" ")
            if sha in seen:
                continue
            seen.add(sha)
            if git("cat-file", "-t", sha).strip() == "blob":
                self.scan_blob(f"(history {sha[:8]}) {path}", git("cat-file", "blob", sha, binary=True))
        log = git("log", "--all", "--format=%H%x00%an%x00%ae%x00%cn%x00%ce%x00%B%x01")
        for rec in filter(str.strip, log.split("\x01")):
            h, an, ae, cn, ce, body = (rec.strip("\n").split("\0") + [""] * 6)[:6]
            self.scan_text(f"(commit {h[:8]} metadata)", "\n".join((an, ae, cn, ce, body)))
            for e in (ae, ce):
                if not e.endswith("@users.noreply.github.com"):
                    self.findings.append((f"(commit {h[:8]})", 0, "author/committer email is not a GitHub noreply address", e))
        for tag in filter(None, git("tag", "-l").split()):
            self.scan_text(f"(tag {tag})", git("cat-file", "-p", tag))


def main():
    args = set(sys.argv[1:]) or {"--worktree"}
    if "--all" in args:
        args = {"--worktree", "--staged", "--history"}
    s = Scanner()
    print(f"privacy-audit: {len(s.terms)} live identifiers loaded from this machine (kept in memory only)")
    if "--worktree" in args:
        s.worktree()
    if "--staged" in args:
        s.staged()
    if "--history" in args:
        s.history()
    if not s.findings:
        print("privacy-audit: clean")
        return 0
    for where, n, cat, v in s.findings:
        loc = f"{where}:{n}" if n else where
        print(f"  {loc:<60} {cat}" + (f"  [{mask(v)}]" if v else ""))
    print(f"privacy-audit: {len(s.findings)} finding(s). Fix them, or allow-list a PUBLIC value in .privacy-allow.")
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as e:
        print(f"privacy-audit: git failed: {e}", file=sys.stderr)
        sys.exit(2)
