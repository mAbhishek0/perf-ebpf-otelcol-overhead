# crash.sh — evidence for a crashed run. Sourced by entry scripts.
#
# crash_init     ERR trap (failing command + file:line call chain), errors
#                file shared with subshells, optional full trace (BENCH_TRACE=1).
# stage NAME     (in lib.sh) records where the script is; log lines carry it.
# crash_report RC  written from the EXIT trap BEFORE cleanup/revert, so it
#                captures the broken state: stage, errors, log tail, container,
#                dmesg, clocks, temps, live tracer/generator processes, disk.

crash_init() {
  CRASH_TS=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$LAPTOP_ROOT/logs" "$STATE_DIR"
  CRASH_ERRFILE="$LAPTOP_ROOT/logs/.errors_${CRASH_TS}_$$"; export CRASH_ERRFILE
  : > "$CRASH_ERRFILE"
  set -o errtrace
  trap '_crash_on_err $? "$BASH_COMMAND"' ERR
  if [[ ${BENCH_TRACE:-0} == 1 ]]; then
    exec {CRASH_TRACE_FD}>"$LAPTOP_ROOT/logs/trace_${CRASH_TS}.txt"
    BASH_XTRACEFD=$CRASH_TRACE_FD
    PS4='+ ${BASH_SOURCE[0]##*/}:${LINENO} ${FUNCNAME[0]:-main}: '
    set -x
    log "full command trace -> logs/trace_${CRASH_TS}.txt"
  fi
}

_crash_on_err() {
  local rc=$1 cmd=$2 i st=""
  for (( i=1; i<${#FUNCNAME[@]}; i++ )); do
    st+="${FUNCNAME[i]}@${BASH_SOURCE[i]##*/}:${BASH_LINENO[i-1]} "
  done
  printf '%s rc=%s stage=%s cmd=%s stack=%s\n' "$(date +%T)" "$rc" "${STAGE:-?}" "$cmd" "$st" \
    >> "${CRASH_ERRFILE:-/dev/null}" 2>/dev/null || true
}

crash_report() {
  local rc=$1 f="$LAPTOP_ROOT/logs/crash_${CRASH_TS:-$(date +%Y%m%d-%H%M%S)}.txt"
  set +x 2>/dev/null
  _sec() { printf '\n##### %s\n' "$1"; timeout 15 bash -c "$1" 2>&1 | tail -n "${2:-80}"; }
  {
    echo "CRASH REPORT  $(date -Is)  exit=$rc  stage=${STAGE:-?}  unit=${BENCH_UNIT:-?}"
    echo "run in flight: ${RUN_BUNDLE:-${PILOT_BUNDLE:-none}} (active=${RUN_ACTIVE:-${PILOT_ACTIVE:-0}})"
    printf '\n##### errors in order — "die" lines and the last entries are the cause; ERR lines can include failures a caller then handled\n'; cat "${CRASH_ERRFILE:-/dev/null}" 2>/dev/null
    [[ -n ${BENCH_LOG:-} ]] && _sec "tail -n 50 '$BENCH_LOG'" 50
    _sec "docker ps -a"
    _sec "docker logs --tail 100 $NGINX_CONTAINER" 100
    _sec "dmesg -T | tail -n 60" 60
    _sec "cat /sys/devices/system/cpu/online; cat /sys/devices/system/cpu/smt/control; cat /sys/devices/system/cpu/cpufreq/boost"
    _sec "grep . /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq"
    _sec "for z in /sys/class/thermal/thermal_zone*; do echo \$(cat \$z/type) \$(cat \$z/temp); done"
    _sec "ps -eo pid,ppid,psr,pcpu,stat,etime,comm | grep -E 'perf|wrk2|nginx|python|otelcol|bash|sleep' | grep -v grep"
    _sec "free -m; df -h '$LAPTOP_ROOT'"
    _sec "systemctl show -p AllowedCPUs system.slice user.slice init.scope bench.slice"
    local b=${RUN_BUNDLE:-${PILOT_BUNDLE:-}}
    if [[ -n $b && -d $b ]]; then
      _sec "ls -la '$b'"
      local x; for x in "$b"/*.log "$b"/*.out; do [[ -f $x ]] && _sec "tail -n 30 '$x'" 30; done
    fi
  } > "$f" 2>&1
  log "crash report: $f"
}
