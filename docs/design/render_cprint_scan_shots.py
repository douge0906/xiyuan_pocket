# -*- coding: utf-8 -*-
"""Render docs/design/cprint_scan_shots.html into per-section PNGs + one overview.

Usage (from docs/design):
    python render_cprint_scan_shots.py

Browser: bundled Playwright chromium (chromium-1248) via executable_path, because the
bundled `chromium_headless_shell` is not installed on this machine.
"""
import os
import pathlib
import sys

from playwright.sync_api import sync_playwright

HERE = pathlib.Path(__file__).resolve().parent
HTML = HERE / "cprint_scan_shots.html"

CHROME_CANDIDATES = [
    os.path.expanduser("~/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe"),
    os.path.expanduser("~/AppData/Local/ms-playwright/chromium-1248/chrome-win/chrome.exe"),
]

SECTIONS = [
    ("sec-01", "cprint_scan_shots_01_list.png"),
    ("sec-02", "cprint_scan_shots_02_filter_sort.png"),
    ("sec-03", "cprint_scan_shots_03_detail_download.png"),
    ("sec-04", "cprint_scan_shots_04_auth_error.png"),
    ("sec-05", "cprint_scan_shots_05_batch_confirm.png"),
    ("sec-06", "cprint_scan_shots_06_icons_fields.png"),
]

OVERVIEW = "cprint_scan_shots_00_all.png"


def launch(p):
    for exe in CHROME_CANDIDATES:
        if exe and os.path.exists(exe):
            try:
                b = p.chromium.launch(headless=True, executable_path=exe)
                print("launched bundled chromium:", exe)
                return b
            except Exception as exc:  # pragma: no cover - environment dependent
                print("bundled chromium failed:", exe, exc)
    try:
        b = p.chromium.launch(headless=True)
        print("launched default chromium")
        return b
    except Exception as exc:
        print("default chromium failed:", exc)
    for channel in ("msedge", "chrome"):
        try:
            b = p.chromium.launch(headless=True, channel=channel)
            print("launched channel:", channel)
            return b
        except Exception as exc:
            print("channel %s failed:" % channel, exc)
    raise RuntimeError("no usable browser found")


def main():
    if not HTML.exists():
        raise SystemExit("missing %s" % HTML)
    with sync_playwright() as p:
        browser = launch(p)
        page = browser.new_page(viewport={"width": 2560, "height": 1400}, device_scale_factor=2)
        page.goto(HTML.as_uri(), wait_until="load")
        page.wait_for_timeout(700)

        for anchor, name in SECTIONS:
            el = page.query_selector("#" + anchor)
            if el is None:
                print("MISSING section:", anchor)
                continue
            out = HERE / name
            el.screenshot(path=str(out))
            box = el.bounding_box()
            print("%-42s %5d x %-5d  %9d B" % (name, box["width"], box["height"], out.stat().st_size))

        out = HERE / OVERVIEW
        page.screenshot(path=str(out), full_page=True)
        print("%-42s full overview        %9d B" % (OVERVIEW, out.stat().st_size))
        browser.close()


if __name__ == "__main__":
    sys.exit(main())
