#!/bin/bash
# Manual "Run Now": read every configured source and apply max immediate demand.
plugin=fanctrlplus; cfg_path=/boot/config/plugins/$plugin; custom=$1; cfg_file=$cfg_path/${plugin}_$custom.cfg
[[ -f $cfg_file ]] || exit 1; source "$cfg_file"; max=${max:-255}; controller_enable=${controller}_enable
script_dir=$(dirname "$(readlink -f "$0")"); source "$script_dir/fanctrl_algo.sh"; source "$script_dir/fanctrl_sensors.sh"
configure_sources
min_pwm_abs=${pwm:-0}; if [[ -n ${idle:-} ]]; then idle_pwm_abs=$idle; else idle_pwm_abs=0; fi
(( idle_pwm_abs > min_pwm_abs )) && idle_pwm_abs=$min_pwm_abs
algo_init
pwm_val=-1; display_temp=*; temp_origin='(Idle)'; hottest=-1000
for ((i=0; i<SRC_COUNT; i++)); do
  if [[ ${SRC_KIND[i]} == temp ]]; then value=$(read_temp_input "${SRC_PATH[i]}"); else value=$(read_disk_temp "${SRC_DISKS[i]}"); fi
  [[ $value =~ ^[0-9]+$ ]] || continue
  demand=$(algo_curve $((value * 1000)) "${SRC_LOW[i]}" "${SRC_HIGH[i]}"); (( demand > pwm_val )) && pwm_val=$demand
  if (( value > hottest )); then hottest=$value; display_temp=$value; temp_origin="(${SRC_LABEL[i]})"; fi
done
(( pwm_val < 0 )) && pwm_val=$idle_pwm_abs
[[ -f $controller_enable ]] && echo 1 > "$controller_enable"; echo "$pwm_val" > "$controller"; sleep 4
fan_path=; if [[ $controller =~ pwm([0-9]+)$ ]]; then fan_path=$(dirname "$controller")/fan${BASH_REMATCH[1]}_input; fi
[[ -n $fan_path && -f $fan_path ]] && rpm=$(cat "$fan_path") || rpm=?
logger -t "$plugin" "Manual Run [${custom}] Temp=${display_temp}°C $temp_origin → PWM=$pwm_val → RPM=$rpm"
mkdir -p "/var/tmp/$plugin"; echo "$display_temp $temp_origin" > "/var/tmp/$plugin/temp_${plugin}_${custom}"
