#!/bin/bash

# FCP_* env overrides exist for the dev harness/tests only (compare
# FCP_SYS_ROOT in include/Common.php); production always uses the defaults.
plugin="fanctrlplusplus"
cfg_path="${FCP_CFG_PATH:-/boot/config/plugins/$plugin}"
loop_script="${FCP_LOOP_SCRIPT:-/usr/local/emhttp/plugins/$plugin/scripts/fanctrlplusplus_loop.sh}"
LOG="${FCP_WATCH_LOG:-/var/log/fanctrlplusplus_array_watch.log}"
LOG_MAX_BYTES=262144
CHECK_INTERVAL="${FCP_CHECK_INTERVAL:-10}"
rc_script="${FCP_RC_SCRIPT:-/etc/rc.d/rc.${plugin}}"
mdcmd="${FCP_MDCMD:-/usr/local/sbin/mdcmd}"
user_stopped_flag="${FCP_USER_STOPPED:-/var/run/fanctrlplusplus.user_stopped}"
script_dir=$(dirname "$(readlink -f "$0")")
source "$script_dir/fanctrl_manual_override.sh"

last_md_state=""
last_decision=""
manual_restore_failed=0
mismatch_streak=0

log() {
  if [[ -f $LOG ]] && (( $(stat -c %s "$LOG" 2>/dev/null || echo 0) > LOG_MAX_BYTES )); then
    tail -c $((LOG_MAX_BYTES / 2)) "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
  echo "[fanctrlplusplus] $(date +'%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

# Log launch decisions only when they change, so a steady state (such as
# "no fans configured") produces one line instead of one line every 10 s.
log_decision() {
  [[ $1 == "$last_decision" ]] && return
  last_decision=$1
  log "$1"
}

# Count cfg files rc.fanctrlplusplus would actually launch a worker for:
# service enabled and a usable fan name (same sanitizing as the rc script).
count_enabled_fans() {
  local cfg service custom count=0
  for cfg in "$cfg_path"/${plugin}_*.cfg; do
    [[ -f $cfg ]] || continue
    service=$(grep -Po '^service="\K[^"]+' "$cfg")
    [[ $service == 1 ]] || continue
    custom=$(grep -Po '^custom="\K[^"]+' "$cfg" | tr -d '\r\n\t ' | tr -cd '[:alnum:]_-')
    [[ -n $custom ]] && ((count++))
  done
  echo "$count"
}

count_running_workers() {
  local n
  n=$(pgrep -c -f "$loop_script" 2>/dev/null)
  [[ $n =~ ^[0-9]+$ ]] || n=0
  echo "$n"
}

log "Array monitor started"

while true; do
  # Track restoration failures with their own flag so a persistent failure
  # logs once instead of alternating with the launch-decision messages.
  if manual_override_expire "$(date +%s)"; then
    manual_restore_failed=0
  elif (( ! manual_restore_failed )); then
    manual_restore_failed=1
    log "Manual override restoration failed; state retained"
  fi
  current_md_state=$(grep -oP 'mdState=\K\w+' < <("$mdcmd" status 2>/dev/null) || echo "")

  if [[ "$current_md_state" != "$last_md_state" ]]; then
    log "Array state changed: $last_md_state → $current_md_state"
    last_md_state="$current_md_state"
    last_decision=""
  fi

  if [[ "$current_md_state" == "STARTED" && ! -f "$user_stopped_flag" ]]; then
    enabled=$(count_enabled_fans)
    running=$(count_running_workers)
    if (( enabled == 0 )); then
      mismatch_streak=0
      log_decision "No enabled fan configurations; nothing to launch"
    elif (( running != enabled )); then
      # Fewer workers than enabled fans means a dead controller; more means
      # duplicates. Both are healed by a relaunch, but only after the
      # mismatch persists for two consecutive passes so transient states
      # (a save's stop/start mid-relaunch) don't trigger a spurious restart.
      mismatch_streak=$((mismatch_streak + 1))
      if (( mismatch_streak >= 2 )); then
        log_decision "Workers/config mismatch ($running running, $enabled enabled) → launching"
        # rc start re-checks the user-stop flag under its own lock, so a
        # concurrent user stop can never be overridden by this launch.
        FCP_RESPECT_USER_STOP=1 "$rc_script" start
        mismatch_streak=0
        # Give workers time to come up before re-evaluating, and re-log if
        # the next pass still finds a mismatch.
        last_decision=""
        sleep "$CHECK_INTERVAL"
      fi
    else
      mismatch_streak=0
      log_decision "Workers running ($running of $enabled fans enabled)"
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
