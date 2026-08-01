#!/bin/bash
# fanctrlplusplus_dashboard_update.sh - 实时更新 Dashboard 所需的 RPM 和 PWM
plugin="fanctrlplusplus"
cfg_path="/boot/config/plugins/$plugin"
tmp_path="/var/tmp/$plugin"
script_dir=$(dirname "$(readlink -f "$0")")
source "$script_dir/fanctrl_manual_override.sh"

mkdir -p "$tmp_path"
exec 9>"/var/run/${plugin}_history.lock"
flock -n 9 || exit 0

record_history() {
  local now=$1 custom=$2 temp_raw=$3 pwm_raw=$4 rpm_raw=$5
  local temp="" source="" pwm="" pwm_percent="" rpm=""
  local history="$tmp_path/history_${plugin}_${custom}.csv"
  local compact_stamp="$tmp_path/.history_compact_${custom}"
  local numeric_temp_re='^[[:space:]]*([-+]?[0-9]+([.][0-9]+)?)[[:space:]]*\(([^)]*)\)[[:space:]]*$'
  local idle_temp_re='^[[:space:]]*\*[[:space:]]*\(([^)]*)\)[[:space:]]*$'

  if [[ "$temp_raw" =~ $numeric_temp_re ]]; then
    temp="${BASH_REMATCH[1]}"
    source="${BASH_REMATCH[3]//,/ }"
  elif [[ "$temp_raw" =~ $idle_temp_re ]]; then
    source="${BASH_REMATCH[1]//,/ }"
  fi
  source=${source//$'\n'/ }
  source=${source//$'\r'/ }
  if [[ "$pwm_raw" =~ ^[0-9]+$ ]]; then
    pwm=$pwm_raw
    pwm_percent=$(((pwm_raw * 100 + 127) / 255))
    (( pwm_percent > 100 )) && pwm_percent=100
  fi
  [[ "$rpm_raw" =~ ^[0-9]+$ ]] && rpm=$rpm_raw

  printf '%s,%s,%s,%s,%s,%s\n' "$now" "$temp" "$source" "$pwm" "$pwm_percent" "$rpm" >> "$history"

  # Timestamp-based retention, with rewrites limited to about once a minute.
  if [[ ! -e "$compact_stamp" || $((now - $(stat -c %Y "$compact_stamp" 2>/dev/null || echo 0))) -ge 60 ]]; then
    local tmp="$history.tmp.$$" cutoff=$((now - 3600))
    awk -F, -v cutoff="$cutoff" '$1 ~ /^[0-9]+$/ && $1 >= cutoff' "$history" > "$tmp" && mv "$tmp" "$history"
    rm -f "$tmp"
    touch "$compact_stamp"
  fi
}

while true; do
  now=$(date +%s)
  manual_override_expire "$now"
  for cfg in "$cfg_path"/${plugin}_*.cfg; do
    [[ -f "$cfg" ]] || continue

    source "$cfg"
    [[ "$service" != "1" ]] && continue
    [[ -z "$controller" || -z "$custom" ]] && continue
    [[ "$custom" =~ ^[A-Za-z0-9_]+$ ]] || continue

    # 提取 fan 路径：从 pwmX 推导为 fanX_input
    if [[ "$controller" =~ pwm([0-9]+)$ ]]; then
      fan_index="${BASH_REMATCH[1]}"
      fan_path="$(dirname "$controller")/fan${fan_index}_input"
    else
      continue
    fi

    # 读取 RPM
    rpm="-"
    [[ -f "$fan_path" ]] && rpm=$(< "$fan_path")

    # ✅ 写入RPM文件
    echo "$rpm" > "$tmp_path/rpm_${plugin}_${custom}"

    # 读取 PWM
    pwm_val="-"
    [[ -f "$controller" ]] && pwm_val=$(< "$controller")

    # ✅ 写入PWM文件
    echo "$pwm_val" > "$tmp_path/pwm_${plugin}_${custom}"

    temp_val=""
    [[ -f "$tmp_path/temp_${plugin}_${custom}" ]] && temp_val=$(< "$tmp_path/temp_${plugin}_${custom}")
    record_history "$now" "$custom" "$temp_val" "$pwm_val" "$rpm"

    # ✅ 状态判断
    if [[ "$rpm" =~ ^[0-9]+$ ]] && (( rpm > 0 )); then
      echo "Running" > "$tmp_path/status_${plugin}_${custom}"
    else
      echo "Stopped" > "$tmp_path/status_${plugin}_${custom}"
    fi
  done

  sleep 5  # dashboard 刷新频率，不影响风扇控制逻辑
done
