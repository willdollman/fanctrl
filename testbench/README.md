# Fan control testbench

Simulates a small server (CPU + 4 HDDs, one PWM case fan) so fan control
algorithms can be compared head-to-head before touching real hardware.

```bash
pip install matplotlib
python3 run.py                     # all controllers x all scenarios
python3 run.py --scenario medium_steady
python3 run.py --controller dual_ema_quiet
```

Outputs a metrics table per scenario (also written to `out/report.md`) and a
timeseries plot per scenario (`out/<scenario>.png`, one row per controller:
red = CPU temp, orange = hottest disk, blue = PWM).

## Layout

| file | contents |
|---|---|
| `sim.py` | thermal plant, fan model, sensor model, sim runner |
| `scenarios.py` | load profiles (`idle_day`, `bursty`, `medium_steady`, `parity_check`, `mixed_day`) |
| `controllers.py` | candidate algorithms |
| `metrics.py` | scoring |
| `run.py` | CLI |

## The model (deliberately simple, properties that matter kept)

- CPU: first-order node, tau ~30s — fast and noisy (sensor jitter sigma 0.8degC)
- HDDs: first-order nodes, tau ~10min — slow, SMART readout quantized to whole degC
  (this quantization is what makes naive linear mapping yo-yo at steady state)
- Fan: PWM -> RPM roughly linear above a stall duty, 2s spin-up lag
- Noise proxy: dBA ~ 38 + 55*log10(rpm/rpm_max) (aerodynamic noise ~5.5th power)
- Cooling: thermal resistance falls nonlinearly with airflow

## Metrics

- `cpu max`, `cpu>80 %`, `disk max`, `disk>50 %` — did it keep things cool
- `dBA mean` (energy-averaged), `dBA p95` — how loud it was overall / at worst
- `trans/h` — audible fan speed *swings* (direction reversals >= 8% RPM);
  the yo-yo annoyance metric. A smooth ramp up and back down counts once.
- `pwm σ steady` — PWM standard deviation over the final third of the run;
  measures whether the fan finds a level and sits there
- `writes/h`, `smart/h` — sysfs write rate and smartctl poll rate (cost)

## Controllers

- `baseline_60s` — the original baseline: one instantaneous sample per
  60s, linear temp->PWM map, 5-count write deadband
- `fast_linear` — same, sampled at 5s/30s (CPU/disk): fixes staleness, keeps jitter
- `smooth_slew` — EMA-filtered temps -> curve -> deadband -> asymmetric slew
  (fast up, slow down) + latched critical-temp override
- `smooth_slew_nl` — same with a non-linear (multi-point) curve, gentle early,
  steep late
- `pi` — clamped PI per source toward a target temp, max() combined.
  Different philosophy: holds a temperature instead of following a curve;
  quietest at steady state, but lets components sit at the setpoint and
  ignores anything below it
- `dual_ema_quiet` — quiet mode: fast EMA (tau 45s) drives the curve but output
  is capped at `quiet_cap` unless a slow EMA (tau 5min) confirms sustained
  heat, which raises the cap; instantaneous critical temps bypass everything
  (latched). Short spikes -> moderate ramp; sustained load -> full range.
- `dual_ema_quiet_int` — exact integer mirror of `dual_ema_quiet` (x1000
  fixed-point EMAs, integer division), matching the shipping bash
  implementation in `../scripts/fanctrl_algo.sh` tick-for-tick.

All algorithms use only integer-friendly math (EMA, clamped accumulator,
piecewise-linear interpolation) so the winner can be ported to the plugin's
bash loop on Unraid. `dual_ema_quiet` won and is what the plugin now ships
(`scripts/fanctrl_algo.sh`).

## Parity test

```bash
python3 test_bash_parity.py
```

Drives `scripts/fanctrl_algo.sh` and `DualEmaQuietInt` through 2400 identical
ticks (noise, ramps, critical spikes, disk standby, CPU sensor dropout, idle)
and asserts every PWM output is byte-identical. Run this after any change to
either implementation.

## Caveats

Thermal constants are plausible, not calibrated to any specific chassis.
Treat absolute temperatures with suspicion; treat *relative* controller
behavior (stability, noise character, response shape) as meaningful.
