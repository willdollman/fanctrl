"""Metrics for judging a fan controller run."""

from __future__ import annotations

import math
from dataclasses import dataclass


@dataclass
class Metrics:
    controller: str
    scenario: str
    cpu_max: float
    cpu_over_80_pct: float
    disk_max: float
    disk_over_50_pct: float
    dba_mean: float          # energy-averaged noise
    dba_p95: float
    transitions_per_h: float  # audible fan speed swings (direction reversals)
    pwm_std_steady: float     # pwm stability in final third of the run
    pwm_writes_per_h: float
    disk_reads_per_h: float


def _energy_mean_dba(dba: list[float]) -> float:
    vals = [10 ** (d / 10.0) for d in dba]
    return 10.0 * math.log10(sum(vals) / len(vals)) if vals else 0.0


def _percentile(xs: list[float], p: float) -> float:
    s = sorted(xs)
    return s[min(len(s) - 1, int(p / 100.0 * len(s)))]


def _audible_swings(rpm: list[float]) -> int:
    """Count fan speed direction reversals a human would notice: the RPM trend
    reverses and the swing is >=8% relative. A single smooth ramp up and back
    down counts as one swing; yo-yoing counts every bounce."""
    # smooth first so 1-tick jitter doesn't register as reversals
    sm, s = [], rpm[0]
    for r in rpm:
        s += (r - s) * 0.2
        sm.append(s)
    n = 0
    anchor = sm[0]       # last extremum that was "heard"
    direction = 1        # +1 rising, -1 falling
    extremum = sm[0]
    for r in sm:
        if direction > 0 and r > extremum:
            extremum = r
        elif direction < 0 and r < extremum:
            extremum = r
        moved = abs(r - extremum)
        if moved > 0.02 * max(extremum, 300.0):  # trend reversed
            swing = abs(extremum - anchor)
            if swing >= 0.08 * max(anchor, 300.0) and max(extremum, anchor) > 300.0:
                n += 1
                anchor = extremum
            direction = 1 if r > extremum else -1
            extremum = r
    return n


def _std(xs: list[float]) -> float:
    m = sum(xs) / len(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / len(xs))


def compute(trace) -> Metrics:
    n = len(trace.t)
    hours = n / 3600.0
    steady = trace.pwm[2 * n // 3:]
    return Metrics(
        controller=trace.name,
        scenario=trace.scenario,
        cpu_max=max(trace.cpu_temp),
        cpu_over_80_pct=100.0 * sum(1 for x in trace.cpu_temp if x > 80.0) / n,
        disk_max=max(trace.disk_temp),
        disk_over_50_pct=100.0 * sum(1 for x in trace.disk_temp if x > 50.0) / n,
        dba_mean=_energy_mean_dba(trace.dba),
        dba_p95=_percentile(trace.dba, 95),
        transitions_per_h=_audible_swings(trace.rpm) / hours,
        pwm_std_steady=_std([float(p) for p in steady]),
        pwm_writes_per_h=trace.pwm_writes / hours,
        disk_reads_per_h=trace.disk_reads / hours,
    )


HEADERS = ["controller", "cpu max", "cpu>80 %", "disk max", "disk>50 %",
           "dBA mean", "dBA p95", "trans/h", "pwm σ steady", "writes/h", "smart/h"]


def row(m: Metrics) -> list[str]:
    return [m.controller,
            f"{m.cpu_max:.1f}", f"{m.cpu_over_80_pct:.1f}",
            f"{m.disk_max:.1f}", f"{m.disk_over_50_pct:.1f}",
            f"{m.dba_mean:.1f}", f"{m.dba_p95:.1f}",
            f"{m.transitions_per_h:.1f}", f"{m.pwm_std_steady:.1f}",
            f"{m.pwm_writes_per_h:.0f}", f"{m.disk_reads_per_h:.0f}"]


def table(ms: list[Metrics]) -> str:
    rows = [HEADERS] + [row(m) for m in ms]
    widths = [max(len(r[i]) for r in rows) for i in range(len(HEADERS))]
    out = []
    for j, r in enumerate(rows):
        out.append("| " + " | ".join(c.ljust(w) for c, w in zip(r, widths)) + " |")
        if j == 0:
            out.append("|" + "|".join("-" * (w + 2) for w in widths) + "|")
    return "\n".join(out)
