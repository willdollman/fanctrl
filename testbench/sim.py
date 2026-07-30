"""Thermal + fan simulation for fan control algorithm evaluation.

Models a small server: one CPU (fast thermal mass, noisy sensor) and a set of
HDDs (slow thermal mass, integer-quantized SMART readout), cooled by one PWM
case fan. Timestep is 1 second.

The plant is deliberately simple (first-order lumped thermal models) but keeps
the properties that matter for controller design:
  - CPU time constant ~30s, disk time constant ~10min
  - cooling effectiveness is a nonlinear function of airflow
  - sensors are noisy (CPU) or quantized (SMART) and cost something to read
  - fan RPM lags PWM commands
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass, field


# ---------------------------------------------------------------------------
# Fan


@dataclass
class Fan:
    rpm_max: float = 1800.0
    stall_duty: float = 0.08     # below this duty the fan stops
    tau: float = 2.0             # spin-up/down time constant, seconds
    rpm: float = 0.0

    def target_rpm(self, pwm: int) -> float:
        duty = max(0.0, min(1.0, pwm / 255.0))
        if duty < self.stall_duty:
            return 0.0
        # roughly linear above the stall region, small floor offset
        return self.rpm_max * (0.15 + 0.85 * duty)

    def step(self, pwm: int, dt: float = 1.0) -> None:
        tgt = self.target_rpm(pwm)
        self.rpm += (tgt - self.rpm) * (1.0 - math.exp(-dt / self.tau))

    @property
    def airflow(self) -> float:
        """Airflow fraction 0..1."""
        return max(0.0, min(1.0, self.rpm / self.rpm_max))

    def noise_dba(self) -> float:
        """Acoustic proxy. Fan aerodynamic noise scales ~5.5th power of speed."""
        if self.rpm < 100:
            return 0.0
        return max(0.0, 38.0 + 55.0 * math.log10(self.rpm / self.rpm_max))


# ---------------------------------------------------------------------------
# Thermal plant


@dataclass
class ThermalNode:
    """First order lumped node: dT/dt = (T_ss - T)/tau,
    T_ss = ambient + P * R(airflow)."""

    tau: float
    r0: float          # thermal resistance scale, degC/W
    a_floor: float     # cooling effectiveness floor with fan stopped (0..1)
    temp: float = 25.0

    def resistance(self, airflow: float) -> float:
        return self.r0 / (self.a_floor + (1.0 - self.a_floor) * airflow)

    def step(self, power: float, ambient: float, airflow: float, dt: float = 1.0) -> None:
        t_ss = ambient + power * self.resistance(airflow)
        self.temp += (t_ss - self.temp) * (1.0 - math.exp(-dt / self.tau))


@dataclass
class Plant:
    n_disks: int = 4
    rng: random.Random = field(default_factory=lambda: random.Random(42))
    cpu: ThermalNode = field(default_factory=lambda: ThermalNode(tau=30.0, r0=0.45, a_floor=0.30))
    disks: list[ThermalNode] = field(default_factory=list)

    # power model
    cpu_p_idle: float = 12.0
    cpu_p_max: float = 130.0
    disk_p_standby: float = 0.4
    disk_p_idle: float = 3.5
    disk_p_active: float = 11.0

    def __post_init__(self) -> None:
        if not self.disks:
            self.disks = [
                ThermalNode(
                    tau=600.0 * self.rng.uniform(0.85, 1.15),
                    r0=1.7 * self.rng.uniform(0.9, 1.1),
                    a_floor=0.35,
                )
                for _ in range(self.n_disks)
            ]

    def step(self, cpu_load: float, disk_io: float, disks_spun: bool,
             ambient: float, airflow: float, dt: float = 1.0) -> None:
        cpu_power = self.cpu_p_idle + (self.cpu_p_max - self.cpu_p_idle) * cpu_load
        self.cpu.step(cpu_power, ambient, airflow, dt)
        for i, d in enumerate(self.disks):
            if not disks_spun:
                p = self.disk_p_standby
            else:
                # spread IO unevenly across disks, like a real array
                share = disk_io * (1.0 if i == 0 else 0.7)
                p = self.disk_p_idle + (self.disk_p_active - self.disk_p_idle) * min(1.0, share)
            d.step(p, ambient, airflow, dt)


# ---------------------------------------------------------------------------
# Sensors (what the controller is allowed to see)


@dataclass
class Sensors:
    plant: Plant
    rng: random.Random = field(default_factory=lambda: random.Random(7))
    cpu_reads: int = 0
    disk_reads: int = 0

    def read_cpu(self) -> float:
        """Like /sys hwmon: cheap, but jittery."""
        self.cpu_reads += 1
        return self.plant.cpu.temp + self.rng.gauss(0.0, 0.8)

    def read_disks(self) -> list[int]:
        """Like smartctl: integer degC, expensive (track read count)."""
        self.disk_reads += 1
        return [int(round(d.temp)) for d in self.plant.disks]


# ---------------------------------------------------------------------------
# Simulation runner


@dataclass
class Trace:
    name: str
    scenario: str
    t: list[int] = field(default_factory=list)
    cpu_temp: list[float] = field(default_factory=list)
    disk_temp: list[float] = field(default_factory=list)  # hottest disk
    pwm: list[int] = field(default_factory=list)
    rpm: list[float] = field(default_factory=list)
    dba: list[float] = field(default_factory=list)
    cpu_load: list[float] = field(default_factory=list)
    disk_io: list[float] = field(default_factory=list)
    ambient: list[float] = field(default_factory=list)
    pwm_writes: int = 0
    disk_reads: int = 0


def run(controller, scenario, duration_s: int, seed: int = 42) -> Trace:
    """Run one controller against one scenario. scenario(t) must return a dict
    with cpu_load, disk_io, disks_spun, ambient."""
    plant = Plant(rng=random.Random(seed))
    sensors = Sensors(plant, rng=random.Random(seed + 1))
    fan = Fan()

    # settle plant at idle for 20 min before the clock starts
    for _ in range(1200):
        plant.step(0.02, 0.0, True, scenario(0)["ambient"], 0.3)
    fan.rpm = fan.target_rpm(110)

    trace = Trace(name=controller.name, scenario=getattr(scenario, "name", "scenario"))
    last_pwm = None

    for t in range(duration_s):
        env = scenario(t)
        pwm = controller.step(t, sensors)
        pwm = max(0, min(255, int(pwm)))
        if pwm != last_pwm:
            trace.pwm_writes += 1
            last_pwm = pwm
        fan.step(pwm)
        plant.step(env["cpu_load"], env["disk_io"], env["disks_spun"],
                   env["ambient"], fan.airflow)

        trace.t.append(t)
        trace.cpu_temp.append(plant.cpu.temp)
        trace.disk_temp.append(max(d.temp for d in plant.disks))
        trace.pwm.append(pwm)
        trace.rpm.append(fan.rpm)
        trace.dba.append(fan.noise_dba())
        trace.cpu_load.append(env["cpu_load"])
        trace.disk_io.append(env["disk_io"])
        trace.ambient.append(env["ambient"])

    trace.disk_reads = sensors.disk_reads
    return trace
