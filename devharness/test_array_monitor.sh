#!/bin/bash
# Regression tests for scripts/array_monitor.sh launch decisions.
# Verifies the monitor does NOT loop `rc start` when there is nothing to
# launch (no cfgs / disabled cfgs / user stop), launches exactly once when an
# enabled fan has no worker, and stays quiet while a worker runs.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"
monitor="$repo/scripts/array_monitor.sh"

pass=0; fail=0
check() { # name condition detail
  if [[ $2 == ok ]]; then echo "PASS $1"; ((pass++)); else echo "FAIL $1 ${3:-}"; ((fail++)); fi
}

run_monitor() { # duration
  ( cd "$tmp" && exec env \
      FCP_CFG_PATH="$tmp/cfg" \
      FCP_LOOP_SCRIPT="$tmp/fake_loop_marker_$$.sh" \
      FCP_WATCH_LOG="$tmp/watch.log" \
      FCP_CHECK_INTERVAL=1 \
      FCP_RC_SCRIPT="$tmp/rc_stub" \
      FCP_MDCMD="$tmp/mdcmd" \
      FCP_USER_STOPPED="$tmp/user_stopped" \
      MANUAL_OVERRIDE_FILE="$tmp/manual_override" \
      MANUAL_OVERRIDE_LOCK="$tmp/manual.lock" \
      "$monitor" ) &
  mon_pid=$!
  sleep "$1"
  kill "$mon_pid" 2>/dev/null
  wait "$mon_pid" 2>/dev/null
}

new_env() {
  tmp=$(mktemp -d)
  mkdir -p "$tmp/cfg"
  cat > "$tmp/mdcmd" <<'EOF'
#!/bin/bash
echo "mdState=STARTED"
EOF
  # rc_stub records every start invocation
  cat > "$tmp/rc_stub" <<EOF
#!/bin/bash
echo "\$1" >> "$tmp/rc_calls"
EOF
  chmod +x "$tmp/mdcmd" "$tmp/rc_stub"
  : > "$tmp/rc_calls"
}

starts() { grep -c '^start$' "$tmp/rc_calls" 2>/dev/null || true; }

# --- 1. no cfg files: never launches, logs decision once --------------------
new_env
run_monitor 4
n=$(starts)
check "no cfgs: rc start never called" "$([[ $n -eq 0 ]] && echo ok)" "starts=$n"
n=$(grep -c 'No enabled fan configurations' "$tmp/watch.log")
check "no cfgs: decision logged exactly once" "$([[ $n -eq 1 ]] && echo ok)" "lines=$n"
rm -rf "$tmp"

# --- 2. only disabled cfgs: never launches ----------------------------------
new_env
printf 'custom="Fan1"\nservice="0"\n' > "$tmp/cfg/fanctrlplusplus_Fan1.cfg"
printf 'custom=""\nservice="1"\n'     > "$tmp/cfg/fanctrlplusplus_temp_0.cfg"
run_monitor 4
n=$(starts)
check "disabled/unnamed cfgs: rc start never called" "$([[ $n -eq 0 ]] && echo ok)" "starts=$n"
rm -rf "$tmp"

# --- 3. enabled cfg without worker: launches (and re-tries, not every tick) --
new_env
printf 'custom="Fan1"\nservice="1"\n' > "$tmp/cfg/fanctrlplusplus_Fan1.cfg"
run_monitor 5
n=$(starts)
check "enabled cfg, no worker: rc start called" "$([[ $n -ge 1 ]] && echo ok)" "starts=$n"
check "launch attempts are throttled" "$([[ $n -le 3 ]] && echo ok)" "starts=$n"
rm -rf "$tmp"

# --- 4. user stopped: never launches -----------------------------------------
new_env
printf 'custom="Fan1"\nservice="1"\n' > "$tmp/cfg/fanctrlplusplus_Fan1.cfg"
touch "$tmp/user_stopped"
run_monitor 4
n=$(starts)
check "user stopped: rc start never called" "$([[ $n -eq 0 ]] && echo ok)" "starts=$n"
rm -rf "$tmp"

# --- 5. worker already running: never launches --------------------------------
new_env
printf 'custom="Fan1"\nservice="1"\n' > "$tmp/cfg/fanctrlplusplus_Fan1.cfg"
cat > "$tmp/fake_loop_marker_$$.sh" <<'EOF'
#!/bin/bash
sleep 60
EOF
chmod +x "$tmp/fake_loop_marker_$$.sh"
"$tmp/fake_loop_marker_$$.sh" & worker_pid=$!
run_monitor 4
kill "$worker_pid" 2>/dev/null; wait "$worker_pid" 2>/dev/null
n=$(starts)
check "worker running: rc start never called" "$([[ $n -eq 0 ]] && echo ok)" "starts=$n"
rm -rf "$tmp"

# --- 6. partial worker death: relaunches (2 enabled, 1 worker) ----------------
new_env
printf 'custom="Fan1"\nservice="1"\n' > "$tmp/cfg/fanctrlplusplus_Fan1.cfg"
printf 'custom="Fan2"\nservice="1"\n' > "$tmp/cfg/fanctrlplusplus_Fan2.cfg"
cat > "$tmp/fake_loop_marker_$$.sh" <<'EOF'
#!/bin/bash
sleep 60
EOF
chmod +x "$tmp/fake_loop_marker_$$.sh"
"$tmp/fake_loop_marker_$$.sh" & worker_pid=$!
run_monitor 5
kill "$worker_pid" 2>/dev/null; wait "$worker_pid" 2>/dev/null
n=$(starts)
check "partial worker death: rc start called" "$([[ $n -ge 1 ]] && echo ok)" "starts=$n"
rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
exit "$((fail > 0))"
