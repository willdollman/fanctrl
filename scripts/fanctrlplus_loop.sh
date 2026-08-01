#!/bin/bash
# Per-fan N-source control loop.
cfg_file="$1"; [[ -f $cfg_file ]] || exit 1
source "$cfg_file"; max=${max:-255}
script_dir=$(dirname "$(readlink -f "$0")")
source "$script_dir/fanctrl_algo.sh"; source "$script_dir/fanctrl_sensors.sh"
configure_sources

min_pwm_abs=${pwm:-0}
if [[ -n ${idle:-} ]]; then idle_pwm_abs=$idle
elif [[ -n ${idle_percent:-} ]]; then idle_pwm_abs=$(((idle_percent * 255 + 50) / 100))
else idle_pwm_abs=0; fi
(( idle_pwm_abs < 0 )) && idle_pwm_abs=0; (( idle_pwm_abs > max )) && idle_pwm_abs=$max
(( idle_pwm_abs > min_pwm_abs )) && idle_pwm_abs=$min_pwm_abs

plugin=fanctrlplus; custom=${custom:-$(basename "$cfg_file" .cfg)}; controller_enable=${controller}_enable
tick=${tick:-5}; disk_poll_s=$((${interval:-1} * 60)); (( disk_poll_s < tick )) && disk_poll_s=$tick
if [[ $controller =~ pwm([0-9]+)$ ]]; then fan_index=${BASH_REMATCH[1]}; fan_path=$(dirname "$controller")/fan${fan_index}_input; else fan_path=; fi
mkdir -p "/var/tmp/$plugin"
log_state() {
  local log_enable rpm
  log_enable=$(grep '^syslog=' "$cfg_file" | cut -d'"' -f2); [[ -n $log_enable && $log_enable != 1 ]] && return
  [[ -n $fan_path && -f $fan_path ]] && rpm=$(cat "$fan_path") || rpm=?
  logger -t "$plugin" "$1[${custom}] Temp=${display_temp}°C $temp_origin → PWM=$A_PWM → RPM=$rpm"
}

algo_init
last_written=-1; last_logged=-1; last_crit=0; next_disk_poll=0; now=0
CURRENT=()
while true; do
  for ((i=0; i<SRC_COUNT; i++)); do
    if [[ ${SRC_KIND[i]} == temp ]]; then ALGO_IN[i]=$(read_temp_input "${SRC_PATH[i]}"); CURRENT[i]=${ALGO_IN[i]}
    elif (( now >= next_disk_poll )); then ALGO_IN[i]=$(read_disk_temp "${SRC_DISKS[i]}"); CURRENT[i]=${ALGO_IN[i]}
    else ALGO_IN[i]=keep
    fi
  done
  (( now >= next_disk_poll )) && next_disk_poll=$((now + disk_poll_s))
  algo_step

  display_temp=*; temp_origin='(Idle)'; hottest=-1000
  for ((i=0; i<SRC_COUNT; i++)); do
    [[ ${CURRENT[i]:--} =~ ^[0-9]+$ ]] || continue
    if (( CURRENT[i] > hottest )); then hottest=${CURRENT[i]}; display_temp=${CURRENT[i]}; temp_origin="(${SRC_LABEL[i]})"; fi
  done
  echo "$display_temp $temp_origin" > "/var/tmp/$plugin/temp_${plugin}_${custom}"
  if (( A_PWM != last_written )); then [[ -f $controller_enable ]] && echo 1 > "$controller_enable"; echo "$A_PWM" > "$controller"; last_written=$A_PWM; fi
  if (( last_logged == -1 )); then log_state ""; last_logged=$A_PWM
  elif (( A_CRIT != last_crit )); then if (( A_CRIT )); then log_state "Critical temp! "; else log_state "Recovered: "; fi; last_logged=$A_PWM
  elif (( A_PWM-last_logged >= 10 || last_logged-A_PWM >= 10 )); then log_state ""; last_logged=$A_PWM; fi
  last_crit=$A_CRIT; sleep "$tick"; now=$((now + tick))
done
