#!/usr/bin/env python3
"""Run all controllers against all scenarios; print comparison tables and
save timeseries plots.

Usage:
    python3 run.py [--out out] [--scenario NAME] [--controller NAME]
"""

from __future__ import annotations

import argparse
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

import controllers
import metrics
import scenarios
import sim


def plot_scenario(scn_name: str, traces: list, outdir: str) -> str:
    n = len(traces)
    fig, axes = plt.subplots(n, 1, figsize=(14, 2.6 * n), sharex=True)
    if n == 1:
        axes = [axes]
    for ax, tr in zip(axes, traces):
        th = [t / 3600.0 for t in tr.t]
        ax.plot(th, tr.cpu_temp, color="tab:red", lw=0.9, label="CPU °C")
        ax.plot(th, tr.disk_temp, color="tab:orange", lw=0.9, label="disk °C")
        ax.plot(th, [a for a in tr.ambient], color="gray", lw=0.6, ls=":", label="ambient")
        ax.set_ylabel(tr.name, rotation=0, ha="right", fontsize=9)
        ax.set_ylim(20, 100)
        ax2 = ax.twinx()
        ax2.plot(th, tr.pwm, color="tab:blue", lw=0.9, alpha=0.85, label="PWM")
        ax2.set_ylim(0, 260)
        ax2.set_yticks([0, 128, 255])
        if ax is axes[0]:
            lines1, labels1 = ax.get_legend_handles_labels()
            lines2, labels2 = ax2.get_legend_handles_labels()
            ax.legend(lines1 + lines2, labels1 + labels2, loc="upper right",
                      fontsize=8, ncol=4)
    axes[-1].set_xlabel("hours")
    fig.suptitle(f"scenario: {scn_name}  (red/orange = temps, blue = PWM)")
    fig.tight_layout()
    path = os.path.join(outdir, f"{scn_name}.png")
    fig.savefig(path, dpi=110)
    plt.close(fig)
    return path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="out")
    ap.add_argument("--scenario", default=None)
    ap.add_argument("--controller", default=None)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    scns = [s() for s in scenarios.ALL]
    if args.scenario:
        scns = [s for s in scns if s.name == args.scenario]

    report = []
    for scn in scns:
        ctrls = controllers.make_all()
        if args.controller:
            ctrls = [c for c in ctrls if c.name == args.controller]
        traces, ms = [], []
        for ctrl in ctrls:
            tr = sim.run(ctrl, scn, scn.duration)
            tr.scenario = scn.name
            traces.append(tr)
            ms.append(metrics.compute(tr))
        png = plot_scenario(scn.name, traces, args.out)
        report.append(f"\n## {scn.name}  ({scn.duration // 3600}h)\n")
        report.append(metrics.table(ms))
        report.append(f"\nplot: {png}")
        print(report[-3])
        print(report[-2])
        print(report[-1])

    with open(os.path.join(args.out, "report.md"), "w") as f:
        f.write("# Fan controller comparison\n" + "\n".join(report) + "\n")


if __name__ == "__main__":
    main()
