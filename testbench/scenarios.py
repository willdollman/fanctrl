"""Load scenarios: each is a callable t -> env dict, with .name and .duration."""

from __future__ import annotations

import math
import random


def _mk(name, duration, fn):
    fn.name = name
    fn.duration = duration
    return fn


def idle_day(seed: int = 3) -> object:
    """Mostly idle box, occasional 30-60s blips (cron jobs, docker healthchecks)."""
    rng = random.Random(seed)
    blips = []
    t = 0
    while t < 2 * 3600:
        t += rng.randint(300, 900)
        blips.append((t, t + rng.randint(30, 60), rng.uniform(0.3, 0.6)))

    def fn(t: int) -> dict:
        load = 0.03
        for s, e, lv in blips:
            if s <= t < e:
                load = lv
                break
        return dict(cpu_load=load, disk_io=0.0, disks_spun=False,
                    ambient=24.0 + math.sin(t / 3600.0) * 0.5)

    return _mk("idle_day", 2 * 3600, fn)


def bursty(seed: int = 5) -> object:
    """CPU spikes to ~90% for 1-3 min every 4-8 min. Disks lightly active.
    The classic 'fan yo-yo' provocation."""
    rng = random.Random(seed)
    spikes = []
    t = 0
    while t < 2 * 3600:
        t += rng.randint(240, 480)
        spikes.append((t, t + rng.randint(60, 180), rng.uniform(0.8, 0.95)))

    def fn(t: int) -> dict:
        load = 0.08
        for s, e, lv in spikes:
            if s <= t < e:
                load = lv
                break
        return dict(cpu_load=load, disk_io=0.15, disks_spun=True, ambient=24.0)

    return _mk("bursty", 2 * 3600, fn)


def medium_steady(seed: int = 9) -> object:
    """Constant medium load (transcode ticking along, moderate IO).
    Disk temps sit mid-band where SMART integer flicker provokes the yo-yo.
    Correct behavior: fan finds a level and SITS there."""
    rng = random.Random(seed)
    noise = [rng.gauss(0, 0.04) for _ in range(2 * 3600)]

    def fn(t: int) -> dict:
        return dict(cpu_load=min(1.0, max(0.0, 0.35 + noise[t % len(noise)])),
                    disk_io=0.5, disks_spun=True, ambient=24.5)

    return _mk("medium_steady", 2 * 3600, fn)


def parity_check(seed: int = 11) -> object:
    """Sustained heavy IO for 3h (parity check / rebuild), moderate CPU.
    Disks heat slowly toward their limit; fan must ramp and hold."""

    def fn(t: int) -> dict:
        active = 600 <= t < 600 + 3 * 3600
        return dict(cpu_load=0.30 if active else 0.05,
                    disk_io=1.0 if active else 0.0,
                    disks_spun=True,
                    ambient=25.0)

    return _mk("parity_check", 4 * 3600, fn)


def mixed_day(seed: int = 13) -> object:
    """6h combined timeline: idle -> bursty hour -> medium 90min ->
    heavy sustained hour -> cool-down."""
    rng = random.Random(seed)
    spikes = []
    t = 3600
    while t < 2 * 3600:
        t += rng.randint(240, 420)
        spikes.append((t, t + rng.randint(60, 150), rng.uniform(0.8, 0.95)))

    def fn(t: int) -> dict:
        if t < 3600:                      # idle
            cpu, io, spun = 0.03, 0.0, False
        elif t < 2 * 3600:                # bursty
            cpu, io, spun = 0.08, 0.1, True
            for s, e, lv in spikes:
                if s <= t < e:
                    cpu = lv
                    break
        elif t < 2 * 3600 + 5400:         # medium steady
            cpu, io, spun = 0.45, 0.35, True
        elif t < 2 * 3600 + 5400 + 3600:  # sustained heavy
            cpu, io, spun = 0.85, 0.9, True
        else:                             # cool-down
            cpu, io, spun = 0.05, 0.0, True
        return dict(cpu_load=cpu, disk_io=io, disks_spun=spun,
                    ambient=24.0 + 1.5 * math.sin(t / (6 * 3600) * math.pi))

    return _mk("mixed_day", 6 * 3600, fn)


ALL = [idle_day, bursty, medium_steady, parity_check, mixed_day]
