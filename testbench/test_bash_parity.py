#!/usr/bin/env python3
"""Prove scripts/fanctrl_algo.sh and controllers.DualEmaQuietInt are the same
algorithm: feed both an identical (cpu, disk) sequence, require identical PWM
output at every step.

Run:  python3 test_bash_parity.py
"""

from __future__ import annotations

import math
import os
import random
import subprocess
import sys

from controllers import DEFAULTS, DualEmaQuietInt

ALGO_SH = os.path.join(os.path.dirname(__file__), "..", "scripts", "fanctrl_algo.sh")

TICK = 5
DISK_PERIOD = 30  # seconds -> fresh disk sample every 6 ticks


def make_sequence(n_ticks: int, seed: int = 123) -> list[tuple]:
    """(cpu, disk) per tick. cpu: int|None. disk: int|None|'keep'.
    Covers: noise, ramps, spikes past crit, disk standby spells, cpu-off spells."""
    rng = random.Random(seed)
    seq = []
    disk_true = 36.0
    for i in range(n_ticks):
        t = i * TICK
        # cpu profile: base + slow wave + spikes, with a dropout spell
        base = 50 + 18 * math.sin(t / 900.0)
        if 3000 <= t < 3600 or 6000 <= t < 7200:
            cpu = None                       # cpu monitoring off
        else:
            spike = 35 if (t // 300) % 7 == 3 else 0   # periodic hard spikes -> crit
            cpu = int(base + spike + rng.gauss(0, 1.2))
        # disk profile: slow drift with a standby spell
        disk_true += rng.gauss(0.005, 0.02)
        if 6000 <= t < 7200:
            disk = None if t % DISK_PERIOD == 0 else "keep"
        elif t % DISK_PERIOD == 0 or i == 0:
            disk = int(round(disk_true + 6 * math.sin(t / 2400.0)))
        else:
            disk = "keep"
        seq.append((cpu, disk))
    return seq


def run_bash(seq) -> list[int]:
    env = dict(
        os.environ,
        pwm=str(DEFAULTS["min_pwm"]), max=str(DEFAULTS["max_pwm"]),
        low=str(DEFAULTS["disk_low"]), high=str(DEFAULTS["disk_high"]),
        cpu_enable="1",
        cpu_min_temp=str(DEFAULTS["cpu_low"]), cpu_max_temp=str(DEFAULTS["cpu_high"]),
        cpu_crit=str(DEFAULTS["cpu_crit"]), disk_crit=str(DEFAULTS["disk_crit"]),
        quiet="1", quiet_cap="150", idle_pwm_abs="0",
        tick=str(TICK), disk_poll_s=str(DISK_PERIOD),
    )
    lines = []
    for cpu, disk in seq:
        c = "-" if cpu is None else str(cpu)
        d = "-" if disk is None else str(disk)
        lines.append(f"{c} {d}")
    proc = subprocess.run(["bash", ALGO_SH, "--test"], input="\n".join(lines) + "\n",
                          capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        sys.exit(f"bash algo failed:\n{proc.stderr}")
    return [int(x) for x in proc.stdout.split()]


def run_python(seq) -> list[int]:
    ctrl = DualEmaQuietInt(tick=TICK, disk_period=DISK_PERIOD, quiet=1,
                           quiet_cap=150, idle_pwm=0)
    return [ctrl.algo_step(cpu, disk) for cpu, disk in seq]


def main() -> None:
    seq = make_sequence(2400)   # 2400 ticks = 3h20m of 5s ticks
    bash_out = run_bash(seq)
    py_out = run_python(seq)
    assert len(bash_out) == len(seq), f"bash produced {len(bash_out)}/{len(seq)} outputs"
    mismatches = [(i, b, p) for i, (b, p) in enumerate(zip(bash_out, py_out)) if b != p]
    if mismatches:
        i, b, p = mismatches[0]
        print(f"FAIL: {len(mismatches)} mismatches; first at tick {i}: bash={b} python={p}")
        print(f"  input around: {seq[max(0, i - 2):i + 1]}")
        sys.exit(1)
    # sanity: the sequence must actually exercise the interesting paths
    assert max(py_out) == DEFAULTS["max_pwm"], "crit/full-speed path never hit"
    assert min(py_out) == 0, "idle path never hit"
    print(f"OK: {len(seq)} ticks identical (pwm range {min(py_out)}..{max(py_out)})")


if __name__ == "__main__":
    main()
