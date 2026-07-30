"""Candidate fan control algorithms.

Every controller exposes .step(t, sensors) -> pwm, called once per simulated
second; the controller decides internally how often to actually sample.

All algorithms here are implementable with integer math in bash (the plugin's
runtime on Unraid) -- EMA as (val*num)//den accumulators, PI with a clamped
integer accumulator, curves as integer interpolation.

Shared config mirrors the plugin: a fan has a min PWM, max PWM, and
low/high temps per source (disk, cpu); per-source demand is combined with max().
"""

from __future__ import annotations

from dataclasses import dataclass, field


DEFAULTS = dict(
    min_pwm=90, max_pwm=255,
    disk_low=38, disk_high=48,
    cpu_low=45, cpu_high=75,
    cpu_crit=90, disk_crit=52,
)


def lerp_curve(temp: float, points: list[tuple[float, int]]) -> float:
    """Piecewise-linear temp->pwm curve. points sorted by temp."""
    if temp <= points[0][0]:
        return points[0][1]
    if temp >= points[-1][0]:
        return points[-1][1]
    for (t0, p0), (t1, p1) in zip(points, points[1:]):
        if t0 <= temp <= t1:
            return p0 + (temp - t0) * (p1 - p0) / (t1 - t0)
    return points[-1][1]


def linear_points(low, high, min_pwm, max_pwm):
    return [(low, min_pwm), (high, max_pwm)]


class Ema:
    """Exponential moving average with time-constant tau (seconds),
    updated at arbitrary intervals."""

    def __init__(self, tau: float):
        self.tau = tau
        self.value: float | None = None

    def update(self, x: float, dt: float) -> float:
        if self.value is None:
            self.value = x
        else:
            alpha = dt / (self.tau + dt)
            self.value += alpha * (x - self.value)
        return self.value


# ---------------------------------------------------------------------------


@dataclass
class BaselineFanctrl:
    """Current fanctrlplus algorithm: instantaneous sample every 60s,
    linear map, write only if |dPWM| >= 5."""

    name: str = "baseline_60s"
    cfg: dict = field(default_factory=lambda: dict(DEFAULTS))
    _pwm: int = -1

    def step(self, t: int, sensors) -> int:
        c = self.cfg
        if self._pwm < 0 or t % 60 == 0:
            cpu = sensors.read_cpu()
            disks = sensors.read_disks()
            cpu_pwm = lerp_curve(cpu, linear_points(c["cpu_low"], c["cpu_high"], c["min_pwm"], c["max_pwm"]))
            disk_pwm = lerp_curve(max(disks), linear_points(c["disk_low"], c["disk_high"], c["min_pwm"], c["max_pwm"]))
            target = int(max(cpu_pwm, disk_pwm))
            if self._pwm < 0 or abs(target - self._pwm) >= 5:
                self._pwm = target
        return self._pwm


@dataclass
class FastLinear:
    """Same algorithm, just sampled fast (cpu 5s, disks 30s).
    Shows what fixing ONLY the refresh rate buys you."""

    name: str = "fast_linear"
    cfg: dict = field(default_factory=lambda: dict(DEFAULTS))
    _pwm: int = -1
    _disk_max: float = 0.0

    def step(self, t: int, sensors) -> int:
        c = self.cfg
        if t % 30 == 0:
            self._disk_max = max(sensors.read_disks())
        if self._pwm < 0 or t % 5 == 0:
            cpu = sensors.read_cpu()
            cpu_pwm = lerp_curve(cpu, linear_points(c["cpu_low"], c["cpu_high"], c["min_pwm"], c["max_pwm"]))
            disk_pwm = lerp_curve(self._disk_max, linear_points(c["disk_low"], c["disk_high"], c["min_pwm"], c["max_pwm"]))
            target = int(max(cpu_pwm, disk_pwm))
            if self._pwm < 0 or abs(target - self._pwm) >= 5:
                self._pwm = target
        return self._pwm


@dataclass
class SmoothSlew:
    """Filtered curve follower: EMA-filtered temps -> curve -> deadband ->
    asymmetric slew limit (ramps up fast, coasts down slowly)."""

    name: str = "smooth_slew"
    cfg: dict = field(default_factory=lambda: dict(DEFAULTS))
    tick: int = 5                 # control period, seconds
    disk_period: int = 30
    up_per_tick: int = 12         # max pwm increase per tick
    down_per_tick: int = 3        # max pwm decrease per tick
    deadband: int = 4
    cpu_points: list | None = None
    disk_points: list | None = None

    def __post_init__(self):
        c = self.cfg
        self.cpu_ema = Ema(20.0)
        self.disk_ema = Ema(90.0)
        self.cpu_points = self.cpu_points or linear_points(c["cpu_low"], c["cpu_high"], c["min_pwm"], c["max_pwm"])
        self.disk_points = self.disk_points or linear_points(c["disk_low"], c["disk_high"], c["min_pwm"], c["max_pwm"])
        self._pwm = -1
        self._raw_cpu = 0.0
        self._raw_disk = 0.0
        self._crit_latched = False

    def _crit(self) -> bool:
        """Critical override with latch: trips at crit, releases 5degC below."""
        c = self.cfg
        if self._raw_cpu >= c["cpu_crit"] or self._raw_disk >= c["disk_crit"]:
            self._crit_latched = True
        elif self._raw_cpu < c["cpu_crit"] - 5 and self._raw_disk < c["disk_crit"] - 5:
            self._crit_latched = False
        return self._crit_latched

    def target(self, t: int, sensors) -> float:
        if t % self.disk_period == 0 or self.disk_ema.value is None:
            self._raw_disk = max(sensors.read_disks())
            self.disk_ema.update(self._raw_disk, self.disk_period)
        self._raw_cpu = sensors.read_cpu()
        cpu_f = self.cpu_ema.update(self._raw_cpu, self.tick)
        cpu_pwm = lerp_curve(cpu_f, self.cpu_points)
        disk_pwm = lerp_curve(self.disk_ema.value, self.disk_points)
        return max(cpu_pwm, disk_pwm)

    def step(self, t: int, sensors) -> int:
        if self._pwm >= 0 and t % self.tick != 0:
            return self._pwm
        target = self.target(t, sensors)
        if self._pwm < 0:
            self._pwm = int(target)
            return self._pwm
        # emergency override beats filtering
        if self._crit():
            self._pwm = self.cfg["max_pwm"]
            return self._pwm
        delta = target - self._pwm
        if abs(delta) <= self.deadband:
            return self._pwm
        step = min(delta, self.up_per_tick) if delta > 0 else max(delta, -self.down_per_tick)
        self._pwm = int(self._pwm + step)
        return self._pwm


@dataclass
class PiController:
    """PI per source toward a target temp, max() combined.
    Kp reacts, clamped Ki removes steady-state error. No D term:
    differentiating a noisy temp sensor is self-harm."""

    name: str = "pi"
    cfg: dict = field(default_factory=lambda: dict(DEFAULTS))
    tick: int = 5
    disk_period: int = 30
    cpu_set: float = 70.0
    disk_set: float = 44.0
    kp_cpu: float = 8.0
    ki_cpu: float = 0.06
    kp_disk: float = 18.0
    ki_disk: float = 0.10

    def __post_init__(self):
        self.cpu_ema = Ema(15.0)
        self.i_cpu = 0.0
        self.i_disk = 0.0
        self._disk_max = 0.0
        self._pwm = -1

    def _pi(self, temp, setpoint, kp, ki, integ, dt, span):
        e = temp - setpoint
        integ = max(0.0, min(span, integ + ki * e * dt))   # clamped integrator
        out = kp * e + integ
        return max(0.0, min(span, out)), integ

    def step(self, t: int, sensors) -> int:
        c = self.cfg
        if self._pwm >= 0 and t % self.tick != 0:
            return self._pwm
        span = c["max_pwm"] - c["min_pwm"]
        if t % self.disk_period == 0 or self._pwm < 0:
            self._disk_max = max(sensors.read_disks())
        cpu = self.cpu_ema.update(sensors.read_cpu(), self.tick)

        out_c, self.i_cpu = self._pi(cpu, self.cpu_set, self.kp_cpu, self.ki_cpu, self.i_cpu, self.tick, span)
        out_d, self.i_disk = self._pi(self._disk_max, self.disk_set, self.kp_disk, self.ki_disk, self.i_disk, self.tick, span)
        new = int(c["min_pwm"] + max(out_c, out_d))
        if self._pwm < 0 or abs(new - self._pwm) >= 3:
            self._pwm = new
        return self._pwm


@dataclass
class DualEmaQuiet:
    """Quiet mode: fast-filtered temp drives the curve, but output is capped
    at quiet_cap unless a slow EMA (sustained heat) raises the cap.
    Instantaneous critical temps bypass everything.

    - short spike: fast target jumps, cap holds it at 'reasonable'
    - sustained load: slow EMA catches up, cap rises to whatever the curve
      demands, up to full blast
    - cool-off: fast target falls quickly, fan follows (min of the two)
    """

    name: str = "dual_ema_quiet"
    cfg: dict = field(default_factory=lambda: dict(DEFAULTS))
    tick: int = 5
    disk_period: int = 30
    quiet_cap: int = 150          # 'reasonable level' ceiling (~59%)
    slow_tau: float = 300.0       # sustained-load detector time constant
    up_per_tick: int = 12
    down_per_tick: int = 3
    deadband: int = 4

    def __post_init__(self):
        c = self.cfg
        # 45s fast filter: blips shorter than ~30s barely move the fan at all;
        # the crit override (latched) covers genuine emergencies.
        self.cpu_fast = Ema(45.0)
        self.cpu_slow = Ema(self.slow_tau)
        self.disk_ema = Ema(90.0)   # disks are already slow; one filter is enough
        self.cpu_points = linear_points(c["cpu_low"], c["cpu_high"], c["min_pwm"], c["max_pwm"])
        self.disk_points = linear_points(c["disk_low"], c["disk_high"], c["min_pwm"], c["max_pwm"])
        self._pwm = -1
        self._raw_cpu = 0.0
        self._raw_disk = 0.0
        self._crit_latched = False

    _crit = SmoothSlew._crit

    def step(self, t: int, sensors) -> int:
        c = self.cfg
        if self._pwm >= 0 and t % self.tick != 0:
            return self._pwm
        if t % self.disk_period == 0 or self.disk_ema.value is None:
            self._raw_disk = max(sensors.read_disks())
            self.disk_ema.update(self._raw_disk, self.disk_period)
        self._raw_cpu = sensors.read_cpu()
        cpu_f = self.cpu_fast.update(self._raw_cpu, self.tick)
        cpu_s = self.cpu_slow.update(self._raw_cpu, self.tick)

        # fast demand: what the curve wants right now
        fast = max(lerp_curve(cpu_f, self.cpu_points),
                   lerp_curve(self.disk_ema.value, self.disk_points))
        # sustained demand: what the curve wants based on long-term heat
        sustained = max(lerp_curve(cpu_s, self.cpu_points),
                        lerp_curve(self.disk_ema.value, self.disk_points))
        cap = max(self.quiet_cap, sustained)
        target = min(fast, cap)

        if self._pwm < 0:
            self._pwm = int(target)
            return self._pwm
        # safety valve: real temps at critical -> full blast now (latched)
        if self._crit():
            self._pwm = c["max_pwm"]
            return self._pwm
        delta = target - self._pwm
        if abs(delta) <= self.deadband:
            return self._pwm
        step = min(delta, self.up_per_tick) if delta > 0 else max(delta, -self.down_per_tick)
        self._pwm = int(self._pwm + step)
        return self._pwm


def make_all() -> list:
    c = DEFAULTS
    nl_cpu = [(c["cpu_low"], c["min_pwm"]), (60, 115), (68, 160), (c["cpu_high"], c["max_pwm"])]
    nl_disk = [(c["disk_low"], c["min_pwm"]), (43, 120), (46, 175), (c["disk_high"], c["max_pwm"])]
    return [
        BaselineFanctrl(),
        FastLinear(),
        SmoothSlew(),
        SmoothSlew(name="smooth_slew_nl", cpu_points=nl_cpu, disk_points=nl_disk),
        PiController(),
        DualEmaQuiet(),
    ]
