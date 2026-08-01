#!/bin/bash
# Shared source configuration and temperature readers.

# Populate zero-based SRC_* arrays from v2 cfg, or synthesize legacy cfg.
configure_sources() {
  SRC_KIND=(); SRC_LOW=(); SRC_HIGH=(); SRC_PATH=(); SRC_DISKS=(); SRC_LABEL=()
  local n=0 i type key
  if [[ -n ${sources:-} ]]; then
    SRC_COUNT=$sources
    for ((i=0; i<SRC_COUNT; i++)); do
      n=$((i + 1)); key=src${n}_type; type=${!key}
      [[ $type == disks ]] && SRC_KIND[i]=disk || SRC_KIND[i]=temp
      key=src${n}_low; SRC_LOW[i]=${!key}
      key=src${n}_high; SRC_HIGH[i]=${!key}
      key=src${n}_path; SRC_PATH[i]=${!key}
      key=src${n}_disks; SRC_DISKS[i]=${!key}
    done
  else
    if [[ -n ${disks:-} ]]; then
      SRC_KIND[n]=disk; SRC_DISKS[n]=$disks; SRC_LOW[n]=${low:-40}; SRC_HIGH[n]=${high:-60}; ((n++))
    fi
    if [[ ${cpu_enable:-0} == 1 && -n ${cpu_sensor:-} ]]; then
      SRC_KIND[n]=temp; SRC_PATH[n]=$cpu_sensor; SRC_LOW[n]=${cpu_min_temp:-40}; SRC_HIGH[n]=${cpu_max_temp:-70}; ((n++))
    fi
    SRC_COUNT=$n
  fi
  for ((i=0; i<SRC_COUNT; i++)); do
    [[ ${SRC_KIND[i]} == disk ]] && SRC_LABEL[i]=Disk || { [[ -n ${cpu_sensor:-} && ${SRC_PATH[i]} == "$cpu_sensor" ]] && SRC_LABEL[i]=CPU || SRC_LABEL[i]=Temp; }
  done
}

read_temp_input() {
  local raw path=$1
  if [[ -f $path ]]; then raw=$(cat "$path"); [[ $raw =~ ^[0-9]+$ ]] && { echo $((raw / 1000)); return; }; fi
  echo -
}
read_cpu_temp() { [[ ${cpu_enable:-0} == 1 ]] && read_temp_input "$cpu_sensor" || echo -; }

# read_disk_temp [comma-list]; defaults to legacy $disks.
read_disk_temp() {
  local list=${1:-${disks:-}} disk disk_path real_path temp max_temp=-1000
  IFS=',' read -ra _disks <<< "$list"
  for disk in "${_disks[@]}"; do
    disk_path="/dev/disk/by-id/$disk"; real_path=$(realpath "$disk_path" 2>/dev/null)
    [[ ! -b $real_path ]] && continue
    smartctl -n standby -A "$real_path" | grep -q "Device is in STANDBY" && continue
    if [[ $real_path == /dev/nvme* ]]; then temp=$(smartctl -A "$real_path" | awk '/Temperature:/ {print $2; exit}')
    else temp=$(smartctl -A "$real_path" | awk '$1 == 190 || $1 == 194 {print $10; exit} $1 == "Temperature_Celsius" {print $10; exit} $1 == "Airflow_Temperature_Cel" {print $10; exit} $1 == "Current" && $3 == "Temperature:" {print $4; exit}')
    fi
    [[ $temp =~ ^[0-9]+$ ]] && (( temp > max_temp )) && max_temp=$temp
  done
  (( max_temp > -1000 )) && echo "$max_temp" || echo -
}
