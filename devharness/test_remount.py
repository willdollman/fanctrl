#!/usr/bin/env python3
"""Regression test: all controls must keep working after Unraid replaces the
mounted page DOM (which drops listeners bound directly to elements)."""
import os
import re
import sys

from playwright.sync_api import sync_playwright

BASE = "http://localhost:8080/Settings/fanctrlplusplus"
CFG_DIR = "/boot/config/plugins/fanctrlplusplus"
CFG = f"{CFG_DIR}/fanctrlplusplus_HDD_Bay.cfg"
HERE = os.path.dirname(os.path.abspath(__file__))

# Reset fixtures
for f in os.listdir(CFG_DIR):
    if f.startswith("fanctrlplusplus_") and f.endswith(".cfg"):
        os.remove(f"{CFG_DIR}/{f}")
for name in ("fanctrlplusplus_HDD_Bay.cfg", "fanctrlplusplus_CPU_Fan.cfg", "order.cfg"):
    src = open(f"{HERE}/fixtures/{name}").read().replace("@FAKESYS@", f"{HERE}/fakesys")
    open(f"{CFG_DIR}/{name}", "w").write(src)

results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(("PASS" if ok else "FAIL"), name, detail)


def read_cfg(path=CFG):
    d = {}
    with open(path) as f:
        for line in f:
            m = re.match(r'^(\w+)="(.*)"$', line.strip())
            if m:
                d[m.group(1)] = m.group(2)
    return d


def remount(page):
    """Simulate Unraid replacing mounted page elements: clone-and-replace the
    whole plugin container, which strips every directly-bound listener."""
    page.evaluate(
        """() => {
        for (const el of document.querySelectorAll('.fcp2')) {
          el.replaceWith(el.cloneNode(true));
        }
    }"""
    )


with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1400, "height": 1000})
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.on("dialog", lambda d: d.accept())
    page.goto(BASE, wait_until="networkidle")
    remount(page)

    hdd = page.locator(".fcp2-card").filter(has=page.locator('input.f-custom[value="HDD_Bay"]'))
    check("card present after remount", hdd.count() == 1)

    # slider sync still works
    minr = hdd.locator("input.f-min-r")
    minr.fill("42")
    minr.dispatch_event("input")
    page.wait_for_timeout(200)
    check("range→number sync after remount", hdd.locator("input.f-min").input_value() == "42")
    check("apply bar shows after remount edit", hdd.locator(".fcp2-applybar").is_visible())

    # Apply still saves
    hdd.locator("button.f-apply").click()
    page.wait_for_timeout(800)
    err = hdd.locator(".f-err").inner_text()
    check("apply saves after remount", err.strip() == "" and read_cfg().get("pwm") == str(round(42 * 255 / 100)),
          f"err={err!r} pwm={read_cfg().get('pwm')}")

    # Add fan still works, and a fully new fan can be created end to end
    n_cards = page.locator(".fcp2-card").count()
    page.locator("#fcp2-addfan").click()
    page.wait_for_timeout(300)
    check("add fan works after remount", page.locator(".fcp2-card").count() == n_cards + 1)

    new = page.locator(".fcp2-card").last
    new.locator("input.f-custom").fill("Remount_Fan")
    new.locator("select.f-controller").select_option(index=1)
    new.locator("button.f-add-temp").click()
    page.wait_for_timeout(200)
    check("add source works after remount", new.locator(".fcp2-src").count() == 1)
    new.locator("input.f-custom").dispatch_event("input")
    new.locator("button.f-apply").click()
    page.wait_for_timeout(800)
    err = new.locator(".f-err").inner_text()
    new_cfg = f"{CFG_DIR}/fanctrlplusplus_Remount_Fan.cfg"
    check("new fan saved after remount", err.strip() == "" and os.path.exists(new_cfg), repr(err))

    # source removal still works (data-saved-name survives the clone;
    # unsaved input *properties* do not, which is fine — config is on disk)
    remount(page)
    new = page.locator('.fcp2-card[data-saved-name="Remount_Fan"]')
    new.locator(".fcp2-src").last.locator("button.rm").click()
    page.wait_for_timeout(200)
    check("remove source works after second remount", new.locator(".fcp2-src").count() == 0)

    # delete still works
    new.locator("button.f-delete").click()
    page.wait_for_timeout(800)
    check("delete works after remount", not os.path.exists(new_cfg))

    # PWM label save still works
    row = page.locator(".fcp2-outrow2").first
    row.locator("input.label-in").fill("Rear exhaust")
    row.locator("button.o-savelabel").click()
    page.wait_for_timeout(500)
    labels = open(f"{CFG_DIR}/pwm_labels.cfg").read() if os.path.exists(f"{CFG_DIR}/pwm_labels.cfg") else ""
    check("label save works after remount", "Rear exhaust" in labels, labels.strip())

    check("no JS page errors", not errors, "; ".join(errors))
    browser.close()

fails = [r for r in results if not r[1]]
print(f"\n{len(results) - len(fails)}/{len(results)} passed")
sys.exit(1 if fails else 0)
