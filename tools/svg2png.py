#!/usr/bin/env python3
"""svg2png.py: save SVG figures as PNG, drawn by a headless Chromium-based browser.

    usage: python3 tools/svg2png.py [--scale 2] [--browser PATH] <figure.svg> ...
    e.g.   python3 tools/svg2png.py docs/images/*.svg

Each <name>.svg becomes <name>.png beside it, --scale times the size of the
SVG viewBox (default 2, so the PNG stays sharp on high-density screens).

Why PNG copies: GitHub shows an SVG with the reader's own fonts, and these
figures ask for Windows fonts first (Cascadia Mono, Consolas, Segoe UI), so on
another system the text can come out wider. The README shows the PNGs, which
look the same for every reader. The SVGs stay the source; edit those.

The browser is --browser if given, otherwise the first one found of chromium,
chromium-browser, google-chrome, microsoft-edge on PATH, then the usual install
places of Chrome and Edge on Windows and macOS. It runs with a throwaway profile
folder, so an open browser window is not touched. The PNGs in docs/images were
made with Microsoft Edge on Windows 11, so they use the Windows fonts.
Python 3 standard library only.
"""
import argparse
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

CANDIDATES = [
    "chromium", "chromium-browser", "google-chrome", "google-chrome-stable", "microsoft-edge",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
]


def find_browser(given):
    for name in ([given] if given else CANDIDATES):
        path = shutil.which(name) or (name if os.path.isfile(name) else None)
        if path:
            return path
    sys.exit("svg2png: no Chromium-based browser found (Chrome, Chromium or Edge); "
             "give one with --browser PATH")


def viewbox_size(svg):
    """(width, height) of the SVG viewBox, as integers."""
    with open(svg, encoding="utf-8") as f:
        head = f.read(4096)
    m = re.search(r'<svg\b[^>]*\bviewBox="\s*[-\d.]+[\s,]+[-\d.]+[\s,]+([\d.]+)[\s,]+([\d.]+)\s*"', head)
    if not m:
        sys.exit(f"svg2png: {svg}: no viewBox on the <svg> element")
    w, h = float(m.group(1)), float(m.group(2))
    if w != int(w) or h != int(h):
        sys.exit(f"svg2png: {svg}: the viewBox size {w} x {h} is not whole pixels")
    return int(w), int(h)


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", head[16:24])


def wait_for_png(png, timeout=60.0):
    """The PNG's size once the browser has written it, or None.

    On Windows msedge.exe hands the work to another process and returns at
    once, so wait until the file is there and has stopped growing.
    """
    last, deadline = None, time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(png):
            size = os.path.getsize(png)
            if size and size == last and png_size(png):
                return png_size(png)
            last = size
        time.sleep(0.5)
    return png_size(png) if os.path.exists(png) else None


def remove_profile(profile, timeout=20.0):
    """Delete the throwaway browser profile (retried while the browser still closes)."""
    deadline = time.monotonic() + timeout
    while os.path.exists(profile) and time.monotonic() < deadline:
        shutil.rmtree(profile, ignore_errors=True)
        if os.path.exists(profile):
            time.sleep(0.5)


def main():
    ap = argparse.ArgumentParser(description="SVG -> PNG with a headless Chromium-based browser")
    ap.add_argument("svgs", nargs="+", metavar="figure.svg")
    ap.add_argument("--scale", type=int, default=2, help="PNG pixels per SVG unit (default 2)")
    ap.add_argument("--browser", help="path or name of Chrome, Chromium or Edge")
    args = ap.parse_args()

    browser = find_browser(args.browser)
    failed = 0
    for svg in args.svgs:
        w, h = viewbox_size(svg)
        png = os.path.splitext(svg)[0] + ".png"
        profile = tempfile.mkdtemp(prefix="svg2png-")
        cmd = [browser, "--headless", "--disable-gpu", "--hide-scrollbars", "--no-first-run",
               "--no-default-browser-check", "--disable-extensions", f"--user-data-dir={profile}",
               f"--force-device-scale-factor={args.scale}", f"--window-size={w},{h}",
               "--default-background-color=ffffffff", f"--screenshot={os.path.abspath(png)}",
               Path(svg).resolve().as_uri()]
        if os.path.exists(png):
            os.remove(png)
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120, check=False)
        got = wait_for_png(png)
        remove_profile(profile)
        want = (w * args.scale, h * args.scale)
        if got == want:
            print(f"svg2png: {svg} -> {png}: {got[0]} x {got[1]} pixels")
        else:
            print(f"svg2png: FAIL {svg}: expected a {want[0]} x {want[1]} PNG, got {got}", file=sys.stderr)
            failed += 1
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
