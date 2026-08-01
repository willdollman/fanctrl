#!/usr/bin/env python3
"""Byte-for-byte parity test for the generalized shell controller."""
import math, os, random, subprocess, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ALGO = os.path.join(ROOT, "scripts/fanctrl_algo.sh")
SENSORS = os.path.join(ROOT, "scripts/fanctrl_sensors.sh")
TICK = 5
KINDS = ("temp", "disk", "temp")
LOWS = (40, 38, 35); HIGHS = (70, 48, 65)

def div0(a, b): return int(a / b)

class GeneralizedMirror:
    def __init__(self):
        self.fast = [-1] * 3; self.slow = [-1] * 3; self.raw = [-1000] * 3
        self.has = [False] * 3; self.pwm = -1; self.crit = False
        self.kf = [(45 + TICK)//TICK, (90 + TICK)//TICK, (45 + TICK)//TICK]
        self.ks = [(300 + TICK)//TICK] * 3
    @staticmethod
    def curve(t, lo, hi):
        if t <= lo*1000: return 90
        if t >= hi*1000: return 255
        return 90 + div0((t-lo*1000)*165, (hi-lo)*1000)
    def step(self, inp):
        fast = sust = -1; hot = False; releasable = True
        for i, x in enumerate(inp):
            if x == "-": self.fast[i] = self.slow[i] = -1; self.raw[i] = -1000; self.has[i] = False
            elif x != "keep":
                x = int(x); self.raw[i] = x; self.has[i] = True
                self.fast[i] = x*1000 if self.fast[i] < 0 else self.fast[i] + div0(x*1000-self.fast[i], self.kf[i])
                self.slow[i] = x*1000 if self.slow[i] < 0 else self.slow[i] + div0(x*1000-self.slow[i], self.ks[i])
            if self.has[i]:
                crit = 52 if KINDS[i] == "disk" else 90
                hot |= self.raw[i] >= crit; releasable &= self.raw[i] < crit-5
                fast = max(fast, self.curve(self.fast[i], LOWS[i], HIGHS[i]))
                sust = max(sust, self.curve(self.slow[i], LOWS[i], HIGHS[i]))
        self.crit |= hot
        if self.crit and not hot and releasable: self.crit = False
        if self.crit: self.pwm = 255; return self.pwm
        no_source = fast < 0
        target = 0 if no_source else min(fast, max(150, sust))
        if self.pwm < 0: self.pwm = target; return self.pwm
        delta = target-self.pwm
        if not no_source and abs(delta) <= 4: return self.pwm
        self.pwm += min(delta, 12) if delta > 0 else max(delta, -3)
        return self.pwm

def sequence(n=2400):
    rng = random.Random(123); out=[]
    for i in range(n):
        # Third source intentionally never reports. All available sources drop
        # out for a long idle stretch. Disk is sampled every six ticks.
        if 1200 <= i < 1320: cpu = "-"
        else:
            cpu = int(52 + 15*math.sin(i/120) + rng.gauss(0, 1))
            if 500 <= i < 510: cpu = 94
            elif 510 <= i < 530: cpu = 86
            elif 530 <= i < 550: cpu = 80
        if i % 6: disk = "keep"
        elif 1200 <= i < 1320 or 800 <= i < 920: disk = "-"  # idle / standby
        else: disk = int(42 + 6*math.sin(i/200))
        out.append((str(cpu), str(disk), "-"))
    return out

def run_bash(seq):
    driver=f'''source "{ALGO}"\nSRC_COUNT=3\nSRC_KIND=(temp disk temp)\nSRC_LOW=(40 38 35)\nSRC_HIGH=(70 48 65)\npwm=90; max=255; idle_pwm_abs=0; quiet=1; quiet_cap=150; tick=5\nalgo_init\nwhile read -r -a ALGO_IN; do algo_step; echo "$A_PWM"; done\n'''
    p=subprocess.run(["bash", "-c", driver], input="\n".join(" ".join(x) for x in seq)+"\n", text=True, capture_output=True, check=True)
    return [int(x) for x in p.stdout.split()]

def check_legacy_synthesis():
    snippet=f'''source "{SENSORS}"
dump() {{ local i; printf '%s' "$SRC_COUNT"; for ((i=0;i<SRC_COUNT;i++)); do printf '|%s,%s,%s,%s,%s' "${{SRC_KIND[i]}}" "${{SRC_LOW[i]}}" "${{SRC_HIGH[i]}}" "${{SRC_DISKS[i]}}" "${{SRC_PATH[i]}}"; done; echo; }}
disks=a,b; low=38; high=48; cpu_enable=1; cpu_sensor=/fake/t; cpu_min_temp=40; cpu_max_temp=70
configure_sources; dump
sources=2; src1_type=disks; src1_disks=a,b; src1_low=38; src1_high=48
src2_type=temp; src2_path=/fake/t; src2_low=40; src2_high=70
configure_sources; dump
'''
    got=subprocess.run(["bash", "-c", snippet], text=True, capture_output=True, check=True).stdout.splitlines()
    assert len(got) == 2 and got[0] == got[1], got

def main():
    seq=sequence(); shell=run_bash(seq); mirror=GeneralizedMirror(); py=[mirror.step(x) for x in seq]
    assert shell == py, next((i, shell[i], py[i], seq[i]) for i in range(len(seq)) if shell[i] != py[i])
    assert max(py)==255 and min(py)==0
    check_legacy_synthesis()
    print(f"OK: {len(seq)} ticks identical (pwm range {min(py)}..{max(py)}); legacy synthesis matches v2")
if __name__ == "__main__": main()
