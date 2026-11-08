# lib.sh — shared helpers. Sourced, never executed. Callers run under
# `set -euo pipefail`, so every helper here is written to be safe under it.

# One locale for every script and child (perf, python, awk, sort), whatever the
# desktop's region settings are: number formats, digit grouping and date/time
# words never depend on the user's Formats choice (it changed to India on
# 2026-11-08). C.UTF-8 keeps UTF-8 text intact. The caller's settings are kept
# for the provenance record.
HOST_LOCALE_ORIG="LANG=${LANG:-} LC_ALL=${LC_ALL:-} LC_TIME=${LC_TIME:-} LC_NUMERIC=${LC_NUMERIC:-}"
export LC_ALL=C.UTF-8

log()  { printf '%s [%s|%s] %s\n' "$(date +%H:%M:%S)" "${LOG_TAG:-bench}" "${STAGE:--}" "$*" >&2; }
warn() { log "WARN: $*"; }
die()  {
  log "FAIL: $*"
  printf '%s die stage=%s: %s (in %s)\n' "$(date +%T)" "${STAGE:-?}" "$*" "${FUNCNAME[1]:-main}" \
    >> "${CRASH_ERRFILE:-/dev/null}" 2>/dev/null || true
  exit 1
}
# stage NAME — where the script is; carried by every log line, kept in state/stage.
stage() {
  STAGE="$*"
  echo "$(date +%T) $STAGE" > "${STATE_DIR:-/tmp}/stage" 2>/dev/null || true
}
need_root() { [[ $EUID -eq 0 ]] || die "run as root: sudo bash $0"; }

# cap VAR cmd...  — capture stdout+stderr into VAR, ignoring the exit status.
# Never pipe a command into `grep -q` under pipefail: a non-zero exit (wrk2's
# usage, SIGPIPE) fails the pipeline even when the text matched.
cap() { local __v=$1; shift; printf -v "$__v" '%s' "$("$@" 2>&1 || true)"; }

# kv_put FILE KEY VALUE / kv_get FILE KEY  — KEY='value' files, single-quoted
# so sourcing never expands them. kv_get fails on a missing key: a missing key
# is a defect, never zero.
kv_put() { local v="${3//\'/}"; printf "%s='%s'\n" "$2" "$v" >> "$1"; }
kv_get() {
  local line
  line="$(grep -m1 "^$2=" "$1" 2>/dev/null)" || die "missing key $2 in $1"
  line="${line#*=}"; line="${line#\'}"; printf '%s' "${line%\'}"
}
kv_has() { grep -q "^$2=" "$1" 2>/dev/null; }

# wait_for TIMEOUT_S DESCRIPTION cmd...  — bounded poll, 0.2 s steps.
wait_for() {
  local t=$1 what=$2; shift 2
  local end=$(( $(date +%s) + t ))
  until "$@" >/dev/null 2>&1; do
    (( $(date +%s) < end )) || return 1
    sleep 0.2
  done
}

# sysw PATH VALUE  — write a sysfs/procfs value and read it back.
sysw() {
  echo "$2" > "$1" 2>/dev/null || return 1
  [[ "$(tr -d ' \n' < "$1")" == "$(tr -d ' \n' <<<"$2")" ]]
}

# Arithmetic on decimals (bash has none).
calc() { awk "BEGIN{ printf \"%.6f\", $* }"; }
pct_diff() { awk -v a="$1" -v b="$2" 'BEGIN{ m=(a+b)/2; if (m==0) {print 0; exit} d=a-b; if (d<0) d=-d; printf "%.4f", 100*d/m }'; }
# rel_spread v1 v2 ...  — (max - min) / mean x 100; 0 when the mean is 0.
rel_spread() { printf '%s\n' "$@" | awk 'NR==1{mn=mx=$1} {s+=$1; if($1<mn)mn=$1; if($1>mx)mx=$1} END{m=s/NR; printf "%.4f", (m ? 100*(mx-mn)/m : 0)}'; }
# rel_spread_trimmed v1 v2 ...  — drop the lowest and highest value (when there
# are at least 5), then (max - min) / median x 100. One stalled run (smoke
# 2026-11-01: B2 p99 449 ms among ~3 ms) must not set the drift limit.
rel_spread_trimmed() {
  printf '%s\n' "$@" | sort -g | awk '{v[NR]=$1} END{
    lo=1; hi=NR; if (NR>=5) { lo=2; hi=NR-1 }
    n=hi-lo+1; m=(n%2) ? v[lo+(n-1)/2] : (v[lo+n/2-1]+v[lo+n/2])/2
    printf "%.4f", (m ? 100*(v[hi]-v[lo])/m : 0) }'
}

# net_snap — TCP counters as "Group:Name value" lines (from /proc/net/snmp and
# /proc/net/netstat, which alternate a header line and a value line).
net_snap() {
  awk 'FNR%2==1 { n=split($0,h); next } { for (i=2;i<=NF;i++) print h[1] h[i], $i }' /proc/net/snmp /proc/net/netstat
}
# net_delta BEFORE AFTER KEY  — after - before for one counter (0 if absent).
net_delta() {
  awk -v k="$3" 'FNR==NR { if ($1==k) a=$2; next } $1==k { b=$2 } END { printf "%d", b-a }' "$1" "$2"
}

gt() { awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a>b) }'; }

# run_prefix  — "L" for block 1 (the original matrices keep their ids), "L_b2"
# for block 2, … (PLAN.md: every cell runs as 2 independent A-B-A blocks);
# "L_cap" for the capacity / drop-onset test (run_workload.sh --capacity).
run_prefix() {
  if (( ${CAPACITY:-0} )); then printf '%s_cap' "$PLATFORM"
  elif (( ${BLOCK:-1} == 1 )); then printf '%s' "$PLATFORM"
  else printf '%s_b%s' "$PLATFORM" "$BLOCK"; fi
}

# capacity_levels RATES  — "40000,44000" -> "R40000,R44000," (literal-rate
# levels, see level_rate); dies on anything but positive integers, or repeats.
capacity_levels() {
  [[ $1 =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]] || die "bad --capacity '$1' (comma list of rates in req/s)"
  local r out="" seen=","
  for r in ${1//,/ }; do
    [[ $seen == *",$r,"* ]] && die "--capacity lists $r twice"
    seen+="$r,"; out+="R$r,"
  done
  printf '%s' "$out"
}

# block_order ORDER_TXT LEVELS  — block 1's last recorded level order, reversed,
# keeping only LEVELS (comma list); one level per line. Used for blocks >= 2.
block_order() {
  local keep=",$2," l
  sed -n 's/.* levels: \(.*\) scopes:.*/\1/p' "$1" | tail -n 1 | tr ' ' '\n' | grep -v '^$' | tac \
    | while read -r l; do [[ $keep == *",$l,"* ]] && printf '%s\n' "$l"; done
  return 0
}

# run_id WL MECH SCOPE LEVEL TRY ROLE  — deterministic, so a rerun collides
# instead of duplicating rows.
run_id() { printf '%s_%s_%s_%s_E%s_try%s_%s' "$(run_prefix)" "$1" "$2" "$3" "$4" "$5" "$6"; }

# level_rate LEVEL  — ladder lookup from the frozen pilot file; "R<n>" is a
# literal rate (pilot only).
level_rate() {
  if [[ "$1" == R* ]]; then printf '%s' "${1#R}"; return; fi
  local pair
  for pair in ${LADDER:?no LADDER — run pilot.sh first}; do
    [[ "${pair%%:*}" == "$1" ]] && { printf '%s' "${pair#*:}"; return; }
  done
  die "level $1 not in LADDER='$LADDER'"
}

# seeded_shuffle SEED item...  — reproducible order; printed one per line.
seeded_shuffle() {
  local seed=$1; shift
  printf '%s\n' "$@" | awk -v s="$seed" 'BEGIN{srand(s)} {printf "%.12f\t%s\n", rand(), $0}' | sort -n | cut -f2
}

# cgroup_usec CGROUP_DIR  — usage_usec from cpu.stat.
cgroup_usec() { awk '$1=="usage_usec"{print $2}' "$1/cpu.stat"; }

# bench_detach UNIT script args...  — re-run the entry script as a transient
# systemd service in BENCH_SLICE. Two reasons: (1) it must live outside the
# slices host.sh restricts to OS_CPUS, or taskset onto workload/tracer CPUs is
# refused; (2) quiesce stops gdm, which would kill a script started from a
# desktop terminal. The launcher follows the log until the service exits; if
# the launcher dies with the desktop, the run continues.
bench_detach() {
  local unit=$1; shift
  [[ ${BENCH_DETACHED:-0} == 1 ]] && return 0
  local logf="$LAPTOP_ROOT/logs/${unit}_$(date +%Y%m%d-%H%M%S).log"
  mkdir -p "$LAPTOP_ROOT/logs"
  if [[ ${QUIESCE:-1} == 1 ]]; then
    source "$LAPTOP_ROOT/common/quiesce.sh"; quiesce_preview
    log "starting in 10 s — Ctrl+C to cancel"; sleep 10
  fi
  systemd-run --unit="$unit" --slice="$BENCH_SLICE" --collect --quiet \
    -E BENCH_DETACHED=1 -E PATH="$PATH" -E QUIESCE="${QUIESCE:-1}" -E ALLOW_GUI="${ALLOW_GUI:-0}" \
    -E BENCH_TRACE="${BENCH_TRACE:-0}" -E BENCH_LOG="$logf" -E BENCH_UNIT="$unit" -E SUDO_USER="${SUDO_USER:-}" \
    -p KillMode=mixed -p TimeoutStopSec=300 \
    -p WorkingDirectory="$PWD" -p StandardOutput="append:$logf" -p StandardError="append:$logf" \
    bash "$@" || die "could not start unit $unit (already running? systemctl status $unit)"
  log "running as unit $unit — log: $logf"
  log "stop: sudo systemctl stop $unit    after a crash: sudo bash $LAPTOP_ROOT/revert.sh"
  sleep 1
  tail -n +1 -F "$logf" --pid="$(systemctl show -p MainPID --value "$unit")" 2>/dev/null || true
  exit 0
}

# pkg_temp_c — CPU die temperature, integer °C. AMD exposes it as hwmon
# k10temp (Tctl); ACPI thermal zones are board sensors that lag the die, so
# they are only the fallback (hottest zone).
# give_back — the harness runs as root; hand everything it wrote in the repo
# back to the invoking user, so git (run as that user) can move and pull it.
give_back() {
  [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]] || return 0
  chown -R "$SUDO_USER:" "$LAPTOP_ROOT" 2>/dev/null || warn "could not chown $LAPTOP_ROOT to $SUDO_USER"
}

pkg_temp_c() {
  local h t m=0 z
  for h in /sys/class/hwmon/hwmon*; do
    if [[ "$(cat "$h/name" 2>/dev/null)" == k10temp && -r $h/temp1_input ]]; then
      echo $(( $(cat "$h/temp1_input") / 1000 )); return
    fi
  done
  for z in /sys/class/thermal/thermal_zone*/temp; do
    t=$(cat "$z" 2>/dev/null || echo 0); (( t > m )) && m=$t
  done
  echo $(( m / 1000 ))
}
