#!/usr/bin/env python3
"""Keep chosen sites logged in across LibreWolf restarts.

LibreWolf wipes cookies + site data on every close (privacy.sanitize.sanitizeOnShutdown).
That stays on; this only adds "Allow" cookie exceptions (same as Settings > Privacy >
Cookies and Site Data > Manage Exceptions > Allow), which are exempt from the wipe.
Exceptions cover subdomains (google.com -> www.google.com, mail.google.com, ...).

Usage: librewolf-keep-logins.py [site ...]   (LibreWolf must be closed)
"""
import configparser
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_SITES = ["google.com", "accounts.google.com", "youtube.com", "github.com"]


def profiles():
    for base in (Path(os.getenv("XDG_CONFIG_HOME", Path.home() / ".config")) / "librewolf/librewolf",
                 Path.home() / ".librewolf"):
        ini = base / "profiles.ini"
        if not ini.exists():
            continue
        cp = configparser.ConfigParser()
        cp.read(ini)
        for sec in cp.sections():
            if sec.startswith("Profile") and "Path" in cp[sec]:
                p = cp[sec]["Path"]
                p = base / p if cp[sec].get("IsRelative", "1") == "1" else Path(p)
                if (p / "prefs.js").exists():
                    yield p


def main():
    if subprocess.run(["pgrep", "-x", "librewolf"], capture_output=True).returncode == 0:
        sys.exit("Close LibreWolf first (it rewrites the permissions database on exit).")
    sites = sys.argv[1:] or DEFAULT_SITES
    now = int(time.time() * 1000)
    found = False
    for prof in profiles():
        found = True
        db = sqlite3.connect(prof / "permissions.sqlite")
        db.execute("CREATE TABLE IF NOT EXISTS moz_perms (id INTEGER PRIMARY KEY,origin TEXT,type TEXT,"
                   "permission INTEGER,expireType INTEGER,expireTime INTEGER,modificationTime INTEGER)")
        for site in sites:
            for scheme in ("https", "http"):
                origin = f"{scheme}://{site}"
                db.execute("DELETE FROM moz_perms WHERE origin=? AND type='cookie'", (origin,))
                db.execute("INSERT INTO moz_perms (origin,type,permission,expireType,expireTime,modificationTime)"
                           " VALUES (?, 'cookie', 1, 0, 0, ?)", (origin, now))
        db.commit()
        db.close()
        print(f"{prof.name}: keeping logins for {', '.join(sites)}")
    if not found:
        sys.exit("No LibreWolf profile found (open LibreWolf once first).")


if __name__ == "__main__":
    main()
