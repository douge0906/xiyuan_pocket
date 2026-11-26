import os, sys, pathlib
from playwright.sync_api import sync_playwright

DESIGN = pathlib.Path("C:/build_ws/xiyuan_pocket/docs/design")
HTML = DESIGN / "cprint_scan_mockup.html"

CHROME_CANDIDATES = [
    os.path.expanduser("~/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe"),
    os.path.expanduser("~/AppData/Local/ms-playwright/chromium-1248/chrome-win/chrome.exe"),
]

def launch(p):
    for exe in CHROME_CANDIDATES:
        if exe and os.path.exists(exe):
            try:
                b = p.chromium.launch(headless=True, executable_path=exe)
                print("launched bundled chromium:", exe)
                return b
            except Exception as e:
                print("bundled launch failed:", exe, e)
    try:
        b = p.chromium.launch(headless=True)
        print("launched default chromium")
        return b
    except Exception as e:
        print("default chromium failed:", e)
    for ch in ("msedge", "chrome"):
        try:
            b = p.chromium.launch(headless=True, channel=ch)
            print("launched channel:", ch)
            return b
        except Exception as e:
            print("channel", ch, "failed:", e)
    raise RuntimeError("no chromium available")

SECTIONS = [
    ("#sec-list",   "cprint_scan_01_list.png"),
    ("#sec-detail", "cprint_scan_02_detail.png"),
    ("#sec-states", "cprint_scan_03_states.png"),
    ("#sec-auth",   "cprint_scan_04_auth.png"),
]

def main():
    with sync_playwright() as p:
        browser = launch(p)
        page = browser.new_page(viewport={"width": 1600, "height": 1200}, device_scale_factor=2)
        page.goto(HTML.as_uri(), wait_until="networkidle")
        page.wait_for_timeout(700)
        for sel, out in SECTIONS:
            el = page.query_selector(sel)
            if el is None:
                print("MISSING", sel); continue
            el.screenshot(path=str(DESIGN / out))
            print("shot", out)
        page.screenshot(path=str(DESIGN / "cprint_scan_00_all.png"), full_page=True)
        print("shot cprint_scan_00_all.png")
        browser.close()

if __name__ == "__main__":
    main()
