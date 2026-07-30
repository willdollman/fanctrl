#!/bin/bash
# fanctrl_algo.sh - fan control algorithm (dual-EMA with quiet mode)
#
# Pure integer math, no I/O. Sourced by fanctrlplus_loop.sh.
# Validated against testbench/controllers.py:DualEmaQuietInt by
# testbench/test_bash_parity.py -- keep the two in sync.
#
# Usage:
#   source this file with cfg vars set (pwm, max, idle, low, high,
#   cpu_min_temp, cpu_max_temp, quiet, quiet_cap, ...), then:
#     algo_init
#     algo_step <cpu_temp|-> <disk_temp|-|keep>   # every tick
#   Result in $A_PWM.
#
#   cpu_temp:  integer degC, or "-" if CPU monitoring disabled/unavailable
#   disk_temp: integer degC of hottest awake disk (fresh sample),
#              "keep" = no new sample this tick (reuse filter state),
#              "-"    = no disk temp available (all standby / none selected)
#
# Algorithm:
#   fast EMA (tau 45s) of CPU temp -> curve -> fast demand
#   slow EMA (tau 300s) of CPU temp -> curve -> sustained demand
#   disk EMA (tau 90s) -> curve  (disks are slow; one filter is enough)
#   quiet mode: output = min(fast, max(quiet_cap, sustained))
#   raw temp >= crit -> full speed, latched until crit-5
#   output smoothed by deadband + asymmetric slew (fast up, slow down)
#
# EMA state is stored scaled x1000 so integer math keeps precision.

algo_init() {
  A_MIN=${pwm:-90}
  A_MAX=${max:-255}
  A_IDLE=${idle_pwm_abs:-0}
  A_TICK=${tick:-5}

  # curve points "temp:pwm temp:pwm ..." (cfg override or linear low/high)
  A_CURVE_DISK=${curve_disk:-"${low:-40}:$A_MIN ${high:-60}:$A_MAX"}
  if [[ "${cpu_enable:-0}" == "1" ]]; then
    A_CURVE_CPU=${curve_cpu:-"${cpu_min_temp:-45}:$A_MIN ${cpu_max_temp:-75}:$A_MAX"}
  else
    A_CURVE_CPU=""
  fi

  # EMA divisors: K = (tau + dt) / dt  ->  ema += (x*1000 - ema) / K
  local disk_dt=${disk_poll_s:-60}
  A_KF=$(( (45 + A_TICK) / A_TICK ))
  A_KS=$(( (300 + A_TICK) / A_TICK ))
  A_KD=$(( (90 + disk_dt) / disk_dt ))
  (( A_KD < 1 )) && A_KD=1

  A_QUIET=${quiet:-0}
  A_QCAP=${quiet_cap:-150}
  (( A_QCAP < A_MIN )) && A_QCAP=$A_MIN
  (( A_QCAP > A_MAX )) && A_QCAP=$A_MAX

  A_CPU_CRIT=${cpu_crit:-90}
  A_DISK_CRIT=${disk_crit:-52}
  A_UP=${slew_up:-12}       # max pwm increase per tick
  A_DOWN=${slew_down:-3}    # max pwm decrease per tick
  A_DB=${deadband:-4}

  A_EMA_CPU_F=-1            # x1000, -1 = unseeded
  A_EMA_CPU_S=-1
  A_EMA_DISK=-1
  A_RAW_CPU=-1000           # last raw readings, -1000 = unavailable
  A_RAW_DISK=-1000
  A_CRIT=0
  A_PWM=-1
}

# algo_curve <temp_x1000> <points> -> echoes pwm
algo_curve() {
  local T=$1 points=$2
  local pts=($points) p t v prev_t prev_v
  local first=${pts[0]} last=${pts[${#pts[@]}-1]}
  local ft=${first%%:*} fv=${first##*:}
  local lt=${last%%:*} lv=${last##*:}
  if (( T <= ft * 1000 )); then echo "$fv"; return; fi
  if (( T >= lt * 1000 )); then echo "$lv"; return; fi
  prev_t=$ft; prev_v=$fv
  for p in "${pts[@]:1}"; do
    t=${p%%:*}; v=${p##*:}
    if (( T <= t * 1000 )); then
      echo $(( prev_v + (T - prev_t * 1000) * (v - prev_v) / ((t - prev_t) * 1000) ))
      return
    fi
    prev_t=$t; prev_v=$v
  done
  echo "$lv"
}

# _algo_ema <state> <sample_degC> <K> -> echoes new state (x1000); seeds if -1
_algo_ema() {
  local ema=$1 x=$2 k=$3
  if (( ema < 0 )); then
    echo $(( x * 1000 ))
  else
    echo $(( ema + (x * 1000 - ema) / k ))
  fi
}

algo_step() {
  local cpu=$1 disk=$2

  # --- update filters ---
  if [[ "$cpu" != "-" ]]; then
    A_RAW_CPU=$cpu
    A_EMA_CPU_F=$(_algo_ema "$A_EMA_CPU_F" "$cpu" "$A_KF")
    A_EMA_CPU_S=$(_algo_ema "$A_EMA_CPU_S" "$cpu" "$A_KS")
  else
    A_RAW_CPU=-1000
    A_EMA_CPU_F=-1
    A_EMA_CPU_S=-1
  fi

  if [[ "$disk" == "-" ]]; then
    A_RAW_DISK=-1000
    A_EMA_DISK=-1
  elif [[ "$disk" != "keep" ]]; then
    A_RAW_DISK=$disk
    A_EMA_DISK=$(_algo_ema "$A_EMA_DISK" "$disk" "$A_KD")
  fi

  # --- demands ---
  local fast=-1 sust=-1 d
  if [[ -n "$A_CURVE_CPU" ]] && (( A_EMA_CPU_F >= 0 )); then
    d=$(algo_curve "$A_EMA_CPU_F" "$A_CURVE_CPU"); (( d > fast )) && fast=$d
    d=$(algo_curve "$A_EMA_CPU_S" "$A_CURVE_CPU"); (( d > sust )) && sust=$d
  fi
  if (( A_EMA_DISK >= 0 )); then
    d=$(algo_curve "$A_EMA_DISK" "$A_CURVE_DISK")
    (( d > fast )) && fast=$d
    (( d > sust )) && sust=$d
  fi

  local target no_source=0
  if (( fast < 0 )); then
    # no temperature source at all -> idle speed
    target=$A_IDLE
    no_source=1
  elif [[ "$A_QUIET" == "1" ]]; then
    local cap=$A_QCAP
    (( sust > cap )) && cap=$sust
    target=$fast
    (( target > cap )) && target=$cap
  else
    target=$fast
  fi

  # --- first run: jump straight to target ---
  if (( A_PWM < 0 )); then
    A_PWM=$target
    return
  fi

  # --- latched critical override on last raw temps ---
  local cpu_hot=0 disk_hot=0
  (( A_RAW_CPU > -1000 && A_RAW_CPU >= A_CPU_CRIT )) && cpu_hot=1
  (( A_RAW_DISK > -1000 && A_RAW_DISK >= A_DISK_CRIT )) && disk_hot=1
  if (( cpu_hot == 1 || disk_hot == 1 )); then
    A_CRIT=1
  elif (( A_CRIT == 1 )); then
    local still=0
    (( A_RAW_CPU > -1000 && A_RAW_CPU >= A_CPU_CRIT - 5 )) && still=1
    (( A_RAW_DISK > -1000 && A_RAW_DISK >= A_DISK_CRIT - 5 )) && still=1
    (( still == 0 )) && A_CRIT=0
  fi
  if (( A_CRIT == 1 )); then
    A_PWM=$A_MAX
    return
  fi

  # --- deadband + asymmetric slew ---
  # (deadband suppresses jitter; idle target is constant, so skip it there)
  local delta=$(( target - A_PWM ))
  local abs_delta=$delta
  (( abs_delta < 0 )) && abs_delta=$(( -abs_delta ))
  (( no_source == 0 && abs_delta <= A_DB )) && return
  if (( delta > 0 )); then
    (( delta > A_UP )) && delta=$A_UP
  else
    (( delta < -A_DOWN )) && delta=$(( -A_DOWN ))
  fi
  A_PWM=$(( A_PWM + delta ))
}

# --- test driver: reads "cpu disk" lines from stdin, prints pwm per line ---
if [[ "${1:-}" == "--test" ]]; then
  algo_init
  while read -r c d; do
    algo_step "$c" "$d"
    echo "$A_PWM"
  done
fi
