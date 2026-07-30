#!/bin/bash
# fanctrl_sensors.sh - temperature readers shared by the control loop and
# the manual-run script. Expects cfg vars: disks, cpu_enable, cpu_sensor.

# read hottest awake disk temp; echoes integer degC or "-"
read_disk_temp() {
  local disk disk_path real_path temp max_temp=-1000
  IFS=',' read -ra _disks <<< "$disks"
  for disk in "${_disks[@]}"; do
    disk_path="/dev/disk/by-id/$disk"
    real_path=$(realpath "$disk_path" 2>/dev/null)
    [[ ! -b "$real_path" ]] && continue

    # skip sleeping disks without waking them
    smartctl -n standby -A "$real_path" | grep -q "Device is in STANDBY" && continue

    if [[ "$real_path" == /dev/nvme* ]]; then
      temp=$(smartctl -A "$real_path" | awk '/Temperature:/ {print $2; exit}')
    else
      temp=$(smartctl -A "$real_path" | awk '
        $1 == 190 || $1 == 194                   { print $10; exit }
        $1 == "Temperature_Celsius"             { print $10; exit }
        $1 == "Airflow_Temperature_Cel"         { print $10; exit }
        $1 == "Current" && $3 == "Temperature:" { print $4; exit }
      ')
    fi

    if [[ "$temp" =~ ^[0-9]+$ ]]; then
      (( temp > max_temp )) && max_temp=$temp
    fi
  done
  if (( max_temp > -1000 )); then echo "$max_temp"; else echo "-"; fi
}

# read CPU temp; echoes integer degC or "-"
read_cpu_temp() {
  local raw
  if [[ "${cpu_enable:-0}" == "1" && -n "$cpu_sensor" && -f "$cpu_sensor" ]]; then
    raw=$(cat "$cpu_sensor")
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      echo $(( raw / 1000 ))
      return
    fi
  fi
  echo "-"
}
