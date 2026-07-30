#!/bin/bash
# fanctrlplus_refresh_single.sh - manual "Run Now": read temps once, apply the
# instantaneous curve target (no filtering -- a manual run should respond
# immediately), write PWM, log.
plugin="fanctrlplus"
cfg_path="/boot/config/plugins/$plugin"
custom="$1"
cfg_file="$cfg_path/${plugin}_$custom.cfg"
[[ -f "$cfg_file" ]] || exit 1
source "$cfg_file"
max="${max:-255}"
controller_enable="${controller}_enable"

script_dir="$(dirname "$(readlink -f "$0")")"
source "$script_dir/fanctrl_algo.sh"
source "$script_dir/fanctrl_sensors.sh"

# idle fallback (same rules as the loop)
min_pwm_abs="${pwm:-0}"
if [[ -n "${idle:-}" ]]; then
  idle_pwm_abs="$idle"
else
  idle_pwm_abs=0
fi
(( idle_pwm_abs > min_pwm_abs )) && idle_pwm_abs="$min_pwm_abs"

algo_init

cpu_temp=$(read_cpu_temp)
disk_temp="-"
[[ -n "$disks" ]] && disk_temp=$(read_disk_temp)

# instantaneous curve demands
cpu_d=-1; disk_d=-1
[[ "$cpu_temp" != "-" && -n "$A_CURVE_CPU" ]] && cpu_d=$(algo_curve $(( cpu_temp * 1000 )) "$A_CURVE_CPU")
[[ "$disk_temp" != "-" ]] && disk_d=$(algo_curve $(( disk_temp * 1000 )) "$A_CURVE_DISK")

if (( cpu_d < 0 && disk_d < 0 )); then
  pwm_val="$idle_pwm_abs"
  display_temp="*"; temp_origin="(Idle)"
elif (( cpu_d > disk_d )); then
  pwm_val=$cpu_d
  display_temp="$cpu_temp"; temp_origin="(CPU)"
else
  pwm_val=$disk_d
  display_temp="$disk_temp"; temp_origin="(Disk)"
fi

# force write PWM
[[ -f "$controller_enable" ]] && echo 1 > "$controller_enable"
echo "$pwm_val" > "$controller"
sleep 4

# read RPM
fan_path=""
if [[ "$controller" =~ pwm([0-9]+)$ ]]; then
  fan_path="$(dirname "$controller")/fan${BASH_REMATCH[1]}_input"
fi
if [[ -n "$fan_path" && -f "$fan_path" ]]; then
  rpm=$(cat "$fan_path")
else
  rpm="?"
fi

logger -t "$plugin" "Manual Run [${custom}] Temp=${display_temp}°C $temp_origin → PWM=$pwm_val → RPM=$rpm"

mkdir -p "/var/tmp/$plugin"
echo "${display_temp} ${temp_origin}" > "/var/tmp/$plugin/temp_${plugin}_${custom}"
