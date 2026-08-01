#!/bin/bash
# Pure-integer N-source dual-EMA controller. The caller sets SRC_COUNT,
# SRC_KIND/SRC_LOW/SRC_HIGH and, before each step, ALGO_IN.

algo_init() {
  A_MIN=${pwm:-90}; A_MAX=${max:-255}; A_IDLE=${idle_pwm_abs:-0}; A_TICK=${tick:-5}
  A_QUIET=${quiet:-0}; A_QCAP=${quiet_cap:-150}
  (( A_QCAP < A_MIN )) && A_QCAP=$A_MIN
  (( A_QCAP > A_MAX )) && A_QCAP=$A_MAX
  A_UP=${slew_up:-12}; A_DOWN=${slew_down:-3}; A_DB=${deadband:-4}
  A_CRIT=0; A_PWM=-1
  A_FAST=(); A_SLOW=(); A_RAW=(); A_HAS=(); A_KF=(); A_KS=()
  local i tau
  for ((i=0; i<${SRC_COUNT:-0}; i++)); do
    [[ ${SRC_KIND[i]} == disk ]] && tau=90 || tau=45
    A_KF[i]=$(( (tau + A_TICK) / A_TICK )); (( A_KF[i] < 1 )) && A_KF[i]=1
    A_KS[i]=$(( (300 + A_TICK) / A_TICK )); (( A_KS[i] < 1 )) && A_KS[i]=1
    A_FAST[i]=-1; A_SLOW[i]=-1; A_RAW[i]=-1000; A_HAS[i]=0
  done
}

algo_curve() {
  local t=$1 lo=$2 hi=$3
  if (( t <= lo * 1000 )); then echo "$A_MIN"
  elif (( t >= hi * 1000 )); then echo "$A_MAX"
  else echo $(( A_MIN + (t - lo * 1000) * (A_MAX - A_MIN) / ((hi - lo) * 1000) ))
  fi
}

_algo_ema() {
  local ema=$1 x=$2 k=$3
  if (( ema < 0 )); then echo $((x * 1000)); else echo $((ema + (x * 1000 - ema) / k)); fi
}

algo_step() {
  local i x d fast=-1 sust=-1 hot=0 releasable=1 crit
  for ((i=0; i<${SRC_COUNT:-0}; i++)); do
    x=${ALGO_IN[i]:--}
    if [[ $x == - ]]; then
      A_FAST[i]=-1; A_SLOW[i]=-1; A_RAW[i]=-1000; A_HAS[i]=0
    elif [[ $x != keep ]]; then
      A_RAW[i]=$x; A_HAS[i]=1
      A_FAST[i]=$(_algo_ema "${A_FAST[i]}" "$x" "${A_KF[i]}")
      A_SLOW[i]=$(_algo_ema "${A_SLOW[i]}" "$x" "${A_KS[i]}")
    fi
    if (( A_HAS[i] )); then
      [[ ${SRC_KIND[i]} == disk ]] && crit=52 || crit=90
      (( A_RAW[i] >= crit )) && hot=1
      (( A_RAW[i] >= crit - 5 )) && releasable=0
      d=$(algo_curve "${A_FAST[i]}" "${SRC_LOW[i]}" "${SRC_HIGH[i]}"); (( d > fast )) && fast=$d
      d=$(algo_curve "${A_SLOW[i]}" "${SRC_LOW[i]}" "${SRC_HIGH[i]}"); (( d > sust )) && sust=$d
    fi
  done
  (( hot )) && A_CRIT=1
  (( A_CRIT && !hot && releasable )) && A_CRIT=0
  if (( A_CRIT )); then A_PWM=$A_MAX; return; fi

  local target no_source=0 cap delta abs_delta
  if (( fast < 0 )); then target=$A_IDLE; no_source=1
  elif [[ $A_QUIET == 1 ]]; then
    cap=$A_QCAP; (( sust > cap )) && cap=$sust
    target=$fast; (( target > cap )) && target=$cap
  else target=$fast
  fi
  if (( A_PWM < 0 )); then A_PWM=$target; return; fi
  delta=$((target - A_PWM)); abs_delta=$delta; (( abs_delta < 0 )) && abs_delta=$((-abs_delta))
  (( !no_source && abs_delta <= A_DB )) && return
  if (( delta > A_UP )); then delta=$A_UP; elif (( delta < -A_DOWN )); then delta=$((-A_DOWN)); fi
  A_PWM=$((A_PWM + delta))
}
