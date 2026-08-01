#!/bin/bash
# Manual override state, exactly six lines in this order:
# controller path, requested PWM, percent, original PWM, original enable mode, expiry epoch.
MANUAL_OVERRIDE_FILE=${MANUAL_OVERRIDE_FILE:-/var/tmp/fanctrlplusplus/manual_override}
MANUAL_OVERRIDE_LOCK=${MANUAL_OVERRIDE_LOCK:-/var/run/fanctrlplusplus_manual.lock}

manual_override_read() {
  local file=${1:-$MANUAL_OVERRIDE_FILE} lines
  [[ -f $file ]] || return 1
  mapfile -t lines < "$file" || return 1
  [[ ${#lines[@]} -eq 6 ]] || return 1
  MANUAL_CONTROLLER=${lines[0]}; MANUAL_PWM=${lines[1]}; MANUAL_PERCENT=${lines[2]}
  MANUAL_ORIGINAL_PWM=${lines[3]}; MANUAL_ORIGINAL_ENABLE=${lines[4]}; MANUAL_EXPIRES=${lines[5]}
  [[ $MANUAL_CONTROLLER =~ ^/[^[:space:]]*/pwm[0-9]+$ ]] || return 1
  [[ $MANUAL_PWM =~ ^[0-9]+$ && $MANUAL_PWM -le 255 ]] || return 1
  [[ $MANUAL_PERCENT =~ ^[0-9]+$ && $MANUAL_PERCENT -ge 10 && $MANUAL_PERCENT -le 100 ]] || return 1
  [[ $MANUAL_ORIGINAL_PWM =~ ^[0-9]+$ && $MANUAL_ORIGINAL_PWM -le 255 ]] || return 1
  [[ $MANUAL_ORIGINAL_ENABLE == - || ( $MANUAL_ORIGINAL_ENABLE =~ ^[0-9]+$ && $MANUAL_ORIGINAL_ENABLE -le 255 ) ]] || return 1
  [[ $MANUAL_EXPIRES =~ ^[0-9]+$ ]] || return 1
}

# Read only the fields needed to safely recover hardware. Requested fields may
# be corrupt, but the file must retain its exact shape and trustworthy originals.
manual_override_recovery_read() {
  local file=${1:-$MANUAL_OVERRIDE_FILE} lines
  [[ -f $file ]] || return 1
  mapfile -t lines < "$file" || return 1
  [[ ${#lines[@]} -eq 6 ]] || return 1
  MANUAL_CONTROLLER=${lines[0]}; MANUAL_PWM=${lines[1]}; MANUAL_PERCENT=${lines[2]}
  MANUAL_ORIGINAL_PWM=${lines[3]}; MANUAL_ORIGINAL_ENABLE=${lines[4]}; MANUAL_EXPIRES=${lines[5]}
  [[ $MANUAL_CONTROLLER =~ ^/[^[:space:]]*/pwm[0-9]+$ ]] || return 1
  [[ $MANUAL_ORIGINAL_PWM =~ ^[0-9]+$ && $MANUAL_ORIGINAL_PWM -le 255 ]] || return 1
  [[ $MANUAL_ORIGINAL_ENABLE == - || ( $MANUAL_ORIGINAL_ENABLE =~ ^[0-9]+$ && $MANUAL_ORIGINAL_ENABLE -le 255 ) ]] || return 1
}

# Caller must hold MANUAL_OVERRIDE_LOCK. State is retained on every failure.
manual_override_restore_locked() {
  local file=${1:-$MANUAL_OVERRIDE_FILE}
  [[ -e $file ]] || return 0
  manual_override_recovery_read "$file" || return 1
  [[ -w $MANUAL_CONTROLLER ]] || return 1
  if [[ $MANUAL_ORIGINAL_ENABLE != - ]]; then
    [[ -w ${MANUAL_CONTROLLER}_enable ]] || return 1
  fi
  printf '%s\n' "$MANUAL_ORIGINAL_PWM" > "$MANUAL_CONTROLLER" || return 1
  if [[ $MANUAL_ORIGINAL_ENABLE != - ]]; then
    printf '%s\n' "$MANUAL_ORIGINAL_ENABLE" > "${MANUAL_CONTROLLER}_enable" || return 1
  fi
  rm -f -- "$file" || return 1
}

manual_override_expire_locked() {
  local now=${1:-$(date +%s)}
  [[ -e $MANUAL_OVERRIDE_FILE ]] || return 0
  if ! manual_override_read; then
    manual_override_restore_locked
  elif (( now >= MANUAL_EXPIRES )); then
    manual_override_restore_locked
  fi
}

manual_override_expire() {
  local now=${1:-$(date +%s)} rc
  exec 8>"$MANUAL_OVERRIDE_LOCK" || return 1
  flock 8 || return 1
  manual_override_expire_locked "$now"; rc=$?
  flock -u 8
  return "$rc"
}

# Serialize every normal controller write with manual mutations/restoration.
# MANUAL_OVERRIDE_APPLIED is 1 when this controller's active override was used.
manual_override_apply() {
  local controller=$1 normal_pwm=$2 now rc=0 target=$2 enable
  MANUAL_OVERRIDE_APPLIED=0
  [[ $normal_pwm =~ ^[0-9]+$ && $normal_pwm -le 255 ]] || return 1
  now=$(date +%s)
  exec 8>"$MANUAL_OVERRIDE_LOCK" || return 1
  flock 8 || return 1
  manual_override_expire_locked "$now" || rc=1
  # A delayed Run Now must not overwrite the 50% service-stop safety value.
  [[ -e /var/run/fanctrlplusplus.user_stopped ]] && rc=1
  if (( rc == 0 )) && manual_override_read && (( now < MANUAL_EXPIRES )) && [[ $MANUAL_CONTROLLER == "$controller" ]]; then
    target=$MANUAL_PWM; MANUAL_OVERRIDE_APPLIED=1
  fi
  if (( rc == 0 )); then
    enable=${controller}_enable
    if [[ -e $enable ]]; then [[ -w $enable ]] && printf '1\n' > "$enable" || rc=1; fi
    if (( rc == 0 )); then [[ -w $controller ]] && printf '%s\n' "$target" > "$controller" || rc=1; fi
  fi
  flock -u 8
  return "$rc"
}
