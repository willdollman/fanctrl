#!/usr/bin/env python3
"""Browser interaction tests for the fanctrlplus card UI."""
import json
import re
import sys
import time

from playwright.sync_api import sync_playwright

BASE = "http://localhost:8080/Settings/fanctrlplus"
CFG = "/boot/config/plugins/fanctrlplus/fanctrlplus_HDD_Bay.cfg"
HERE = "/home/user/workspace/fanctrlplus/devharness"

# Reset fixtures so the test is idempotent
import os, subprocess
for f in os.listdir("/boot/config/plugins/fanctrlplus"):
    if f.startswith("fanctrlplus_") and f.endswith(".cfg"):
        os.remove(f"/boot/config/plugins/fanctrlplus/{f}")
for name in ("fanctrlplus_HDD_Bay.cfg", "fanctrlplus_CPU_Fan.cfg", "order.cfg"):
    src = open(f"{HERE}/fixtures/{name}").read().replace("@FAKESYS@", f"{HERE}/fakesys")
    open(f"/boot/config/plugins/fanctrlplus/{name}", "w").write(src)

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


def card(page, name):
    return page.locator(f'.fcp2-card[data-saved-name="{name}"], .fcp2-card').filter(
        has=page.locator(f'input.f-custom[value="{name}"]')
    ).first


with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1400, "height": 1000})
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(BASE, wait_until="networkidle")

    hdd = page.locator(".fcp2-card").filter(has=page.locator('input.f-custom[value="HDD_Bay"]'))
    check("HDD card present", hdd.count() == 1)

    # 1. Dirty tracking: apply bar hidden initially, shown after edit
    bar = hdd.locator(".fcp2-applybar")
    check("apply bar hidden initially", not bar.is_visible())
    minr = hdd.locator("input.f-min-r")
    minr.fill("35")
    minr.dispatch_event("input")
    page.wait_for_timeout(200)
    check("apply bar shows after edit", bar.is_visible())

    # 2. Apply -> saved, bar hides, cfg updated on disk
    hdd.locator("button.f-apply").click()
    page.wait_for_timeout(800)
    err = hdd.locator(".f-err").inner_text()
    check("no error after apply", err.strip() == "", err)
    check("apply bar hides after save", not bar.is_visible())
    cfg = read_cfg()
    check("pwm=35% persisted", cfg.get("pwm") == str(round(35 * 255 / 100)), cfg.get("pwm"))
    check("other fields intact: quiet_cap", cfg.get("quiet_cap") == "150", cfg.get("quiet_cap"))
    check("other fields intact: sources", cfg.get("sources") == "2", cfg.get("sources"))
    check("other fields intact: src1_disks unchanged", cfg.get("src1_disks", "").count(",") == 3)
    check("legacy mirror: low/high", cfg.get("low") == "38" and cfg.get("high") == "48",
          f"low={cfg.get('low')} high={cfg.get('high')}")

    # 3. Reload -> value persisted in UI
    page.goto(BASE, wait_until="networkidle")
    hdd = page.locator(".fcp2-card").filter(has=page.locator('input.f-custom[value="HDD_Bay"]'))
    check("min speed persisted after reload", hdd.locator("input.f-min-r").input_value() == "35")

    # 4. Validation: low >= high -> error, no write
    before = open(CFG).read()
    low = hdd.locator(".fcp2-src").nth(1).locator("input.f-src-low")
    low.fill("60")
    low.dispatch_event("input")
    page.wait_for_timeout(200)
    hdd.locator("button.f-apply").click()
    page.wait_for_timeout(800)
    err = hdd.locator(".f-err").inner_text()
    check("validation error shown for low>=high", err.strip() != "", repr(err))
    check("cfg not modified on validation error", open(CFG).read() == before)
    # revert
    hdd.locator("button.f-revert").click()
    page.wait_for_load_state("networkidle")

    # 5. Add a sensor source, pick a path, apply
    hdd = page.locator(".fcp2-card").filter(has=page.locator('input.f-custom[value="HDD_Bay"]'))
    n_before = hdd.locator(".fcp2-src").count()
    hdd.locator("button.f-add-temp").click()
    page.wait_for_timeout(200)
    check("source row added", hdd.locator(".fcp2-src").count() == n_before + 1)
    newsrc = hdd.locator(".fcp2-src").last
    sel = newsrc.locator("select.f-src-path")
    opts = sel.locator("option").all_inner_texts()
    check("sensor dropdown has hwmon options", len(opts) >= 2, str(opts))
    sel.select_option(index=len(opts) - 1)
    newsrc.locator("input.f-src-low").fill("40")
    newsrc.locator("input.f-src-high").fill("70")
    newsrc.locator("input.f-src-low").dispatch_event("input")
    hdd.locator("button.f-apply").click()
    page.wait_for_timeout(800)
    err = hdd.locator(".f-err").inner_text()
    check("3rd source saved without error", err.strip() == "", err)
    cfg = read_cfg()
    check("sources=3 on disk", cfg.get("sources") == "3", cfg.get("sources"))
    check("src3 has path", cfg.get("src3_type") == "temp" and "temp" in cfg.get("src3_path", ""),
          cfg.get("src3_path"))

    # 6. Remove the source again
    page.goto(BASE, wait_until="networkidle")
    hdd = page.locator(".fcp2-card").filter(has=page.locator('input.f-custom[value="HDD_Bay"]'))
    hdd.locator(".fcp2-src").last.locator("button.rm").click()
    page.wait_for_timeout(200)
    hdd.locator("button.f-apply").click()
    page.wait_for_timeout(800)
    cfg = read_cfg()
    check("source removed, sources=2", cfg.get("sources") == "2", cfg.get("sources"))

    # 7. Rename fan -> file renamed, old file gone
    hdd = page.locator(".fcp2-card").filter(has=page.locator('input.f-custom[value="HDD_Bay"]'))
    name_in = hdd.locator("input.f-custom")
    name_in.fill("HDD_Bay2")
    name_in.dispatch_event("input")
    hdd.locator("button.f-apply").click()
    page.wait_for_timeout(800)
    import os
    check("renamed file exists", os.path.exists("/boot/config/plugins/fanctrlplus/fanctrlplus_HDD_Bay2.cfg"))
    check("old file removed", not os.path.exists(CFG))
    order = open("/boot/config/plugins/fanctrlplus/order.cfg").read()
    check("order.cfg updated", "HDD_Bay2" in order and "HDD_Bay\n" not in order.replace("HDD_Bay2", ""), order.strip())
    # rename back
    page.goto(BASE, wait_until="networkidle")
    hdd = page.locator(".fcp2-card").filter(has=page.locator('input.f-custom[value="HDD_Bay2"]'))
    name_in = hdd.locator("input.f-custom")
    name_in.fill("HDD_Bay")
    name_in.dispatch_event("input")
    hdd.locator("button.f-apply").click()
    page.wait_for_timeout(800)
    check("renamed back", os.path.exists(CFG))

    # 8. Add fan + delete fan
    page.goto(BASE, wait_until="networkidle")
    n_cards = page.locator(".fcp2-card").count()
    page.locator("#fcp2-addfan").click()
    page.wait_for_timeout(800)
    check("card added", page.locator(".fcp2-card").count() == n_cards + 1)
    newcard = page.locator(".fcp2-card").last
    page.on("dialog", lambda d: d.accept())
    newcard.locator("button.f-delete").click()
    page.wait_for_timeout(800)
    check("card deleted", page.locator(".fcp2-card").count() == n_cards)

    # 9. Quiet toggle off -> cap row hidden; persists
    hdd = page.locator(".fcp2-card").filter(has=page.locator('input.f-custom[value="HDD_Bay"]'))
    quiet = hdd.locator("input.f-quiet")
    quiet.locator("xpath=ancestor::label").click()  # styled toggle hides the input
    page.wait_for_timeout(200)
    hdd.locator("button.f-apply").click()
    page.wait_for_timeout(800)
    cfg = read_cfg()
    check("quiet=0 persisted", cfg.get("quiet") == "0", cfg.get("quiet"))
    check("quiet_cap retained while off", cfg.get("quiet_cap") == "150", cfg.get("quiet_cap"))
    quiet.locator("xpath=ancestor::label").click()
    page.wait_for_timeout(200)
    hdd.locator("button.f-apply").click()
    page.wait_for_timeout(800)
    check("quiet=1 restored", read_cfg().get("quiet") == "1")

    check("no JS page errors", not errors, "; ".join(errors))
    browser.close()

fails = [r for r in results if not r[1]]
print(f"\n{len(results) - len(fails)}/{len(results)} passed")
sys.exit(1 if fails else 0)
