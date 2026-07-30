#!/bin/bash
# fanctrlplus_loop.sh - per-fan control loop (Disk + CPU temperature sources)
#
# Control runs on a fast tick (default 5s): CPU temp is a cheap sysfs read.
# Disks are polled via smartctl every `interval` minutes (SMART is expensive
# and disk temps move slowly). The algorithm itself (dual-EMA filtering,
# quiet mode, critical override, slew limiting) lives in fanctrl_algo.sh.

cfg_file="$1"
[[ -f "$cfg_file" ]] || exit 1
source "$cfg_file"
max="${max:-255}"

script_dir="$(dirname "$(readlink -f "$0")")"
source "$script_dir/fanctrl_algo.sh"
source "$script_dir/fanctrl_sensors.sh"

# ===== Fan Speed on Idle (ABS) =====
min_pwm_abs="${pwm:-0}"

if [[ -n "${idle:-}" ]]; then
  idle_pwm_abs="$idle"
elif [[ -n "${idle_percent:-}" ]]; then
  idle_pwm_abs=$(( (idle_percent * 255 + 50) / 100 ))
else
  idle_pwm_abs=0
fi
(( idle_pwm_abs < 0 )) && idle_pwm_abs=0
(( idle_pwm_abs > max )) && idle_pwm_abs="$max"
(( idle_pwm_abs > min_pwm_abs )) && idle_pwm_abs="$min_pwm_abs"

plugin="fanctrlplus"
custom="${custom:-$(basename "$cfg_file" .cfg)}"
controller_enable="${controller}_enable"

# control cadence
tick="${tick:-5}"                              # control loop period, seconds
disk_poll_s=$(( ${interval:-1} * 60 ))         # disk smartctl cadence
(( disk_poll_s < tick )) && disk_poll_s=$tick

# derive RPM path for logging
if [[ "$controller" =~ pwm([0-9]+)$ ]]; then
  fan_index="${BASH_REMATCH[1]}"
  fan_path="$(dirname "$controller")/fan${fan_index}_input"
else
  fan_path=""
fi

mkdir -p "/var/tmp/$plugin"

log_state() {  # $1 = prefix (e.g. "" or "Critical temp! ")
  local log_enable rpm
  log_enable=$(grep '^syslog=' "$cfg_file" | cut -d'"' -f2)
  [[ -n "$log_enable" && "$log_enable" != "1" ]] && return
  if [[ -n "$fan_path" && -f "$fan_path" ]]; then
    rpm=$(cat "$fan_path")
  else
    rpm="?"
  fi
  logger -t "$plugin" "$1[${custom}] Temp=${display_temp}°C $temp_origin → PWM=$A_PWM → RPM=$rpm"
}

algo_init

last_written=-1
last_logged=-1
last_crit=0
next_disk_poll=0
now=0
disk_temp="-"

while true; do
  cpu_temp=$(read_cpu_temp)

  if (( now >= next_disk_poll )); then
    if [[ -n "$disks" ]]; then
      disk_temp=$(read_disk_temp)
    else
      disk_temp="-"
    fi
    disk_arg="$disk_temp"
    next_disk_poll=$(( now + disk_poll_s ))
  else
    disk_arg="keep"
    [[ "$disk_temp" == "-" ]] && disk_arg="-"
  fi

  algo_step "$cpu_temp" "$disk_arg"

  # figure out display temp + origin (highest instantaneous curve demand wins)
  if [[ "$cpu_temp" == "-" && "$disk_temp" == "-" ]]; then
    display_temp="*"; temp_origin="(Idle)"
  elif [[ "$disk_temp" == "-" ]]; then
    display_temp="$cpu_temp"; temp_origin="(CPU)"
  elif [[ "$cpu_temp" == "-" ]]; then
    display_temp="$disk_temp"; temp_origin="(Disk)"
  else
    cpu_d=$(algo_curve $(( cpu_temp * 1000 )) "$A_CURVE_CPU")
    disk_d=$(algo_curve $(( disk_temp * 1000 )) "$A_CURVE_DISK")
    if (( cpu_d > disk_d )); then
      display_temp="$cpu_temp"; temp_origin="(CPU)"
    else
      display_temp="$disk_temp"; temp_origin="(Disk)"
    fi
  fi
  echo "${display_temp} ${temp_origin}" > "/var/tmp/$plugin/temp_${plugin}_${custom}"

  # write PWM only when the algorithm moved it
  if (( A_PWM != last_written )); then
    [[ -f "$controller_enable" ]] && echo 1 > "$controller_enable"
    echo "$A_PWM" > "$controller"
    last_written=$A_PWM
  fi

  # syslog: first run, critical transitions, or audible change (>=10)
  if (( last_logged == -1 )); then
    log_state ""
    last_logged=$A_PWM
  elif (( A_CRIT != last_crit )); then
    if (( A_CRIT == 1 )); then log_state "Critical temp! "; else log_state "Recovered: "; fi
    last_logged=$A_PWM
  elif (( A_PWM - last_logged >= 10 || last_logged - A_PWM >= 10 )); then
    log_state ""
    last_logged=$A_PWM
  fi
  last_crit=$A_CRIT

  sleep "$tick"
  now=$(( now + tick ))
done
