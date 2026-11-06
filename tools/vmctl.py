#!/usr/bin/env python3
"""Talk to a test VM through QEMU's QMP socket (no extra tools needed).

  vmctl.py SOCK shot OUT.png        screenshot of the VM's screen
  vmctl.py VNCSOCK vncshot OUT.png  screenshot through the VM's local VNC socket (works with 3D GPU)
  vmctl.py SOCK type "text"         type text (US key names; \\n = Enter)
  vmctl.py SOCK key ctrl-alt-f2     press one key combination
  vmctl.py SOCK quit                power off immediately
"""
import json
import socket
import sys
import tempfile
import time
from pathlib import Path

SHIFTED = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
           '_': 'minus', '+': 'equal', '{': 'bracket_left', '}': 'bracket_right', '|': 'backslash',
           ':': 'semicolon', '"': 'apostrophe', '~': 'grave_accent', '<': 'comma', '>': 'dot', '?': 'slash'}
PLAIN = {' ': 'spc', '\n': 'ret', '\t': 'tab', '-': 'minus', '=': 'equal', '[': 'bracket_left',
         ']': 'bracket_right', '\\': 'backslash', ';': 'semicolon', "'": 'apostrophe', '`': 'grave_accent',
         ',': 'comma', '.': 'dot', '/': 'slash'}


class QMP:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self.f = self.s.makefile("rw")
        self.f.readline()
        self.cmd("qmp_capabilities")

    def cmd(self, name, **args):
        self.f.write(json.dumps({"execute": name, "arguments": args}) + "\n")
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if "return" in r or "error" in r:
                if "error" in r:
                    raise SystemExit(f"QMP {name}: {r['error']}")
                return r["return"]


def keys_for(ch):
    if ch.isalpha():
        return (["shift", ch.lower()] if ch.isupper() else [ch])
    if ch.isdigit():
        return [ch]
    if ch in SHIFTED:
        return ["shift", SHIFTED[ch]]
    if ch in PLAIN:
        return [PLAIN[ch]]
    raise SystemExit(f"can't type {ch!r}")


def send(q, names):
    q.cmd("send-key", keys=[{"type": "qcode", "data": k} for k in names], **{"hold-time": 40})
    time.sleep(0.06)


def vncshot(path, out):
    """Minimal RFB 3.8 client: no auth (local unix socket), raw encoding, one full frame."""
    import struct
    from PIL import Image
    s = socket.socket(socket.AF_UNIX)
    s.connect(path)
    s.settimeout(20)

    def rx(n):
        b = b""
        while len(b) < n:
            c = s.recv(n - len(b))
            if not c:
                raise SystemExit("VNC closed")
            b += c
        return b
    rx(12)
    s.sendall(b"RFB 003.008\n")
    types = rx(rx(1)[0])
    if 1 not in types:
        raise SystemExit("VNC needs auth")
    s.sendall(b"\x01")
    if struct.unpack(">I", rx(4))[0] != 0:
        raise SystemExit("VNC security failed")
    s.sendall(b"\x01")
    w, h = struct.unpack(">HH", rx(4))
    rx(16)
    rx(struct.unpack(">I", rx(4))[0])
    # 32bpp, depth 24, little endian, true colour, R<<16 G<<8 B
    s.sendall(struct.pack(">B3xBBBBHHHBBB3x", 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
    s.sendall(struct.pack(">BxHi", 2, 1, 0))
    s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))
    img = Image.new("RGB", (w, h))
    got = 0
    while got < w * h:
        t = rx(1)[0]
        if t != 0:
            if t == 2:
                continue
            if t == 3:
                rx(3); rx(struct.unpack(">I", rx(4))[0]); continue
            if t == 1:
                rx(1); n = struct.unpack(">HH", rx(4))[1]; rx(6 * n); continue
            raise SystemExit(f"VNC message {t}")
        rx(1)
        for _ in range(struct.unpack(">H", rx(2))[0]):
            x, y, rw, rh, enc = struct.unpack(">HHHHi", rx(12))
            if enc != 0:
                if enc == -223:   # desktop size change
                    w, h = rw, rh; img = Image.new("RGB", (w, h))
                    s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h)); got = 0
                continue
            data = rx(rw * rh * 4)
            img.paste(Image.frombytes("RGB", (rw, rh), data, "raw", "BGRX"), (x, y))
            got += rw * rh
    img.save(out)


def main():
    sock, op = sys.argv[1], sys.argv[2]
    if op == "vncshot":
        return vncshot(sock, sys.argv[3])
    q = QMP(sock)
    if op == "shot":
        from PIL import Image
        with tempfile.TemporaryDirectory() as d:
            ppm = Path(d) / "s.ppm"
            q.cmd("screendump", filename=str(ppm))
            for _ in range(50):
                if ppm.exists() and ppm.stat().st_size > 0:
                    break
                time.sleep(0.1)
            time.sleep(0.3)
            Image.open(ppm).save(sys.argv[3])
    elif op == "type":
        for ch in sys.argv[3].encode().decode("unicode_escape"):
            send(q, keys_for(ch))
    elif op == "key":
        send(q, sys.argv[3].split("-"))
    elif op == "quit":
        q.cmd("quit")


if __name__ == "__main__":
    main()
