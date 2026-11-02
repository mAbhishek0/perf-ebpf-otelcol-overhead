#!/usr/bin/env bash
# diag_stall.sh — find the source of the ~1.00 s latency stalls. Entry point.
#
#   sudo bash diag_stall.sh [--rate 20000] [--reps 5] [--variants base,isolgen]
#
# The nginx x perf matrix (2026-11-01) showed requests delayed by up to exactly
# 1.00 s in 21 of 64 runs, untraced baselines included, TCP retransmits zero,
# never at 40k. This runs nginx UNTRACED, same host setup as the matrix, and
# changes one thing per variant:
#   base       as in the matrix (1 Hz sampler on, wrk2 -t2 -c100, fans max)
#   nosampler  no 1 Hz sampler            -> is our own sampler the trigger?
#   c20        wrk2 -c20 instead of -c100 -> per-connection effect in wrk2/nginx?
#   fanauto    fans on firmware auto      -> EC/ACPI activity from the fan curve?
#   isolgen    wrk2 + probe on TRACER_CPUS (idle when untraced) instead of
#              GEN_CPUS, which it otherwise shares with OS slices and IRQs
#   quiet      every timer and background service stopped, radios blocked,
#              user.slice frozen (quiet_on in common/quiesce.sh)
#   isolquiet  both of the above
# Run 1 (2026-11-01, base/nosampler/c20/fanauto) put the stall inside wrk2:
# probe never slow, ~2200 requests >= 893 ms = both wrk2 threads paused ~1 s.
# Run 2 (base/isolgen/quiet/isolquiet) ruled out core sharing and host noise:
# stalls in 5/5, 2/5, 5/5, 4/5; probe never above 8 ms; always ~1.00 s.
# Run 3 keeps base and isolgen and records what happens during a stall
# (capture() below): wrk2's sockets and threads every 100 ms, and every
# off-CPU interval of a wrk2 thread >= 50 ms with its stacks.
# Every run also has a probe: one curl per 100 ms on its own connection, with
# timestamps, so a stall is located in time and we see whether it is
# system-wide (probe stalls too) or confined to wrk2's connections.
# Variants are interleaved rep by rep so slow drift spreads across them.
# Every run also saves /proc/interrupts around the window and the top
# CPU-time processes afterwards, to see what else ran on the wrk2 cores.
# Output: nginx-wrk2/diag/<time>/report.txt and one bundle per run.

set -euo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
LOG_TAG=diag
need_root
bench_detach "bench-diag" "$0" "$@"

RATE=20000 REPS=5 VARIANTS="base,isolgen"
while (( $# )); do
  case $1 in
    --rate) RATE=$2; shift 2 ;;
    --reps) REPS=$2; shift 2 ;;
    --variants) VARIANTS=$2; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done

command -v bpftrace >/dev/null || die "bpftrace missing"
command -v ss >/dev/null || die "ss missing"
for f in crash host preflight quiesce sample cooldown; do source "$LAPTOP_ROOT/common/$f.sh"; done
crash_init
taskset -cp "$OS_CPUS" $$ >/dev/null || die "cannot pin harness to $OS_CPUS"
source "$LAPTOP_ROOT/nginx-wrk2/workload.sh"
DEF_CONNS=$WRK2_CONNS DEF_GEN=$GEN_CPUS

D="$WL_DIR/diag/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$D/raw"

# offcpu.bt PID — every off-CPU interval >= 50 ms of a thread of PID, printed
# when it ends, with the kernel and user stacks it left the CPU with.
# prev_state 0 = preempted while runnable (run-queue wait), else it slept.
# The wrk2 main thread sleeps for the whole window, so one ~120 s line per run
# is expected and is not a stall.
cat > "$D/offcpu.bt" <<'EOF'
tracepoint:sched:sched_switch
{
  if (pid == $1) {
    @off[args.prev_pid] = nsecs;
    @st[args.prev_pid] = args.prev_state;
    @ks[args.prev_pid] = kstack;
    @us[args.prev_pid] = ustack(8);
  }
  $n = args.next_pid;
  if (@off[$n] != 0) {
    $d = (nsecs - @off[$n]) / 1000000;
    if ($d >= 50) {
      time("%H:%M:%S ");
      printf("tid %d off %d ms prev_state %d\n", $n, $d, @st[$n]);
      print(@ks[$n]);
      print(@us[$n]);
    }
    @off[$n] = 0;
  }
}
END { clear(@off); clear(@st); clear(@ks); clear(@us); }
EOF
timeout -s INT 5 bpftrace -q -o /dev/null "$D/offcpu.bt" $$ 2> "$D/bt_check.err" || true
grep -qi error "$D/bt_check.err" && die "offcpu.bt does not load: $(head -n 3 "$D/bt_check.err")"

QUIESCED=0
trap 'quiet_off; (( QUIESCED )) && quiesce_restore' EXIT
if [[ ${QUIESCE:-1} == 1 ]]; then QUIESCED=1; quiesce; fi
preflight_common
wl_preflight
preflight_finish

HOST_SET=0 PILOT_BUNDLE="" PILOT_ACTIVE=0 PROBE_PID="" CAP_PID=""
on_exit() {
  local rc=$?
  set +e
  trap - ERR
  (( rc != 0 )) && crash_report "$rc"
  [[ -n $PROBE_PID ]] && kill "$PROBE_PID" 2>/dev/null
  [[ -n $CAP_PID ]] && kill "$CAP_PID" 2>/dev/null
  [[ -f $PILOT_BUNDLE/pids.bpf ]] && kill -INT "$(cat "$PILOT_BUNDLE/pids.bpf")" 2>/dev/null
  if (( PILOT_ACTIVE )); then
    [[ -f $PILOT_BUNDLE/pids.sampler ]] && kill "$(cat "$PILOT_BUNDLE/pids.sampler")" 2>/dev/null
    [[ -f $PILOT_BUNDLE/pids.gen ]] && kill "$(cat "$PILOT_BUNDLE/pids.gen")" 2>/dev/null
    wl_stop
    touch "$PILOT_BUNDLE/INCOMPLETE"
  fi
  quiet_off
  if (( HOST_SET )); then host_snapshot post; host_snapshot_diff pre post; host_revert; fi
  (( QUIESCED )) && quiesce_restore
  give_back
  (( rc == 0 )) && log "done — report: $D/report.txt" || log "exited with status $rc — host reverted"
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM
host_setup; HOST_SET=1
host_snapshot pre
cooldown_calibrate

fans_auto() { local d n; d=$(_fan_dir) || return 0; for n in $(_fan_nums "$d"); do sysw "$d/pwm${n}_enable" 2 || return 1; done; }

# probe OUT DURATION_S — one request per 100 ms on a fresh connection.
probe() {
  local out=$1 end=$(( SECONDS + $2 )) t
  while (( SECONDS < end )); do
    t=$(curl -s -o /dev/null -m 3 -w '%{time_total}' "$URL" 2>/dev/null) || t=ERR
    printf '%s %s\n' "$(date +%s.%N)" "$t" >> "$out"
    sleep 0.1
  done
}

# conn.tsv, every 100 ms, one ss call over port 8080 (columns in its header).
# Client sockets with segs_out < 50 (the probe's short-lived curls) are left
# out. During a stall cli_min_lastsnd climbs towards 1000: no wrk2 connection
# has sent for that long. Then cli_recvq > 0 means responses sit unread (wrk2
# is not running), srv_recvq > 0 means requests sit unread (nginx), both 0
# means wrk2 stopped sending with nothing outstanding.
_conn_snap() {
  ss -tinH state established '( dport = :8080 or sport = :8080 )' 2>/dev/null | awk -v now="$1" '
    /^[^ \t]/ { if ($1 ~ /^[0-9]+$/) { rq=$1+0; sq=$2+0; loc=$3 } else { rq=$2+0; sq=$3+0; loc=$4 }
                srv = (loc ~ /:8080$/); next }
    { so=0; ls=-1; rt=0
      for (i=1; i<=NF; i++) {
        if ($i ~ /^segs_out:/) so=substr($i,10)+0
        else if ($i ~ /^lastsnd:/) ls=substr($i,9)+0
        else if ($i ~ /^retrans:/) { split($i,a,"/"); rt=a[2]+0 } }
      if (srv) { ns++; srq+=rq; ssq+=sq; next }
      if (so < 50) next
      nc++; crq+=rq; csq+=sq; cso+=so; crt+=rt
      if (ls >= 0) { if (!seen || ls < mn) mn=ls; if (ls > mx) mx=ls; seen=1 } }
    END { printf "%s %d %d %d %d %d %d %d %d %d %d\n", now, nc, crq, csq, cso, (seen ? mn : -1), mx, crt, ns, srq, ssq }'
}

# thr.tsv: epoch, then tid:state:cpu:utime+stime ticks:run_ns:wait_ns per wrk2
# thread (schedstat wait_ns = time runnable but not running).
_thr_snap() {
  local line=$1 t s r w; local -a f
  for t in /proc/$2/task/*; do
    read -r s < "$t/stat" 2>/dev/null || continue
    read -ra f <<<"${s##*) }"
    read -r r w _ < "$t/schedstat" 2>/dev/null || { r=0; w=0; }
    line+=" ${t##*/}:${f[0]}:${f[36]}:$(( f[11] + f[12] )):$r:$w"
  done
  echo "$line"
}

# capture BUNDLE CPUS — background, alongside wl_measure, on CPUS (cores
# neither wrk2 nor nginx use). Waits for wrk2's pid, attaches offcpu.bt to it,
# snapshots until wrk2 exits.
capture() {
  local b=$1 pid="" i now bt
  taskset -cp "$2" $BASHPID >/dev/null || true
  for (( i=0; i<100; i++ )); do [[ -s $b/pids.gen ]] && { pid=$(cat "$b/pids.gen"); break; }; sleep 0.05; done
  [[ -n $pid ]] || { echo "no wrk2 pid within 5 s" > "$b/capture.err"; return 0; }
  bpftrace -q -o "$b/offcpu.txt" "$D/offcpu.bt" "$pid" 2> "$b/bpftrace.err" & bt=$!
  echo "$bt" > "$b/pids.bpf"
  echo "# epoch n_cli cli_recvq cli_sendq cli_segs_out cli_min_lastsnd cli_max_lastsnd cli_retrans n_srv srv_recvq srv_sendq" > "$b/conn.tsv"
  echo "# epoch tid:state:cpu:ticks:run_ns:wait_ns ..." > "$b/thr.tsv"
  while kill -0 "$pid" 2>/dev/null; do
    now=$EPOCHREALTIME
    _conn_snap "$now" >> "$b/conn.tsv"
    _thr_snap "$now" "$pid" >> "$b/thr.tsv"
    sleep 0.1
  done
  kill -INT "$bt" 2>/dev/null; wait "$bt" 2>/dev/null || true
  rm -f "$b/pids.bpf"
}

diag_run() {  # diag_run VARIANT REP
  local v=$1 rep=$2 b t0 sampler=1 quiet=0 cap
  b="$D/raw/${v}_r${rep}"; mkdir -p "$b"
  PILOT_BUNDLE=$b PILOT_ACTIVE=1
  WRK2_CONNS=$DEF_CONNS GEN_CPUS=$DEF_GEN
  case $v in
    base) ;;
    nosampler) sampler=0 ;;
    c20) WRK2_CONNS=20 ;;
    fanauto) fans_auto || warn "could not set fans to auto" ;;
    isolgen) GEN_CPUS=$TRACER_CPUS ;;
    quiet) quiet=1 ;;
    isolquiet) GEN_CPUS=$TRACER_CPUS quiet=1 ;;
    *) die "unknown variant $v" ;;
  esac
  stage "diag $v r$rep"
  log "diag $v rep $rep: rate $RATE, conns $WRK2_CONNS, sampler $sampler, wrk2 on $GEN_CPUS, quiet $quiet"
  (( quiet )) && quiet_on
  cooldown_wait "$b"
  wl_start "$b"
  wl_ramp "$RATE" "$b"
  (( sampler )) && GEN_CPUS=$DEF_GEN sample_start "$b"   # sampler stays on the OS cores
  cat /proc/interrupts > "$b/irq_pre.txt"
  cat /proc/vmstat > "$b/vmstat_pre.txt"; cat /proc/net/netstat /proc/net/snmp > "$b/net_pre.txt"
  [[ $GEN_CPUS == "$TRACER_CPUS" ]] && cap=$DEF_GEN || cap=$TRACER_CPUS
  ( set +e; trap - ERR EXIT; capture "$b" "$cap" ) &
  CAP_PID=$!
  t0=$(date +%s.%N); echo "$t0" > "$b/t0"
  taskset -c "$GEN_CPUS" bash -c "$(declare -f probe); URL='$URL'; probe '$b/probe.txt' $STEADY_S" &
  PROBE_PID=$!
  wl_measure "$RATE" "$b"
  kill "$PROBE_PID" 2>/dev/null || true; wait "$PROBE_PID" 2>/dev/null || true; PROBE_PID=""
  wait "$CAP_PID" 2>/dev/null || true; CAP_PID=""
  cat /proc/interrupts > "$b/irq_post.txt"
  cat /proc/vmstat > "$b/vmstat_post.txt"; cat /proc/net/netstat /proc/net/snmp > "$b/net_post.txt"
  ps -eo pid,psr,cputime,cls,rtprio,cgroup:60,comm --sort=-cputime 2>/dev/null | head -n 60 > "$b/ps_post.txt" || true
  (( sampler )) && sample_stop "$b"
  wl_stop
  (( quiet )) && quiet_off
  wl_parse "$b"
  dmesg -T 2>/dev/null | tail -n 30 > "$b/dmesg_tail.txt" || true
  [[ $v == fanauto ]] && { fans_max >/dev/null || warn "could not restore full-speed fans"; }
  touch "$b/DONE"; PILOT_ACTIVE=0
}

IFS=, read -ra VLIST <<<"$VARIANTS"
for (( rep=1; rep<=REPS; rep++ )); do
  for v in "${VLIST[@]}"; do diag_run "$v" "$rep"; done
done
WRK2_CONNS=$DEF_CONNS GEN_CPUS=$DEF_GEN

# --- report ---
stage "report"
{
  echo "stall diagnostic  rate=$RATE  window=${STEADY_S}s  reps=$REPS  $(date -Is)"
  echo "stall = wrk2 max latency >= 900 ms; probe = 1 curl / 100 ms on its own connection"
  echo "idle_ms = longest time no wrk2 connection sent (conn.tsv peak cli_min_lastsnd), at_s after t0,"
  echo "  with cli_rq / srv_rq = bytes unread by wrk2 / by nginx at that moment; off_ms = longest"
  echo "  off-CPU interval of a wrk2 worker thread (offcpu.txt, main thread excluded), st = its prev_state"
  echo
  printf '%-10s %3s %8s %8s %9s %6s | %9s %6s %5s | %7s %5s %7s %7s | %6s %2s\n' variant rep p99_ms p999_ms max_ms stall \
    probe_max p_slow first idle_ms at_s cli_rq srv_rq off_ms st
  for v in "${VLIST[@]}"; do
    for (( rep=1; rep<=REPS; rep++ )); do
      b="$D/raw/${v}_r${rep}"; e="$b/wl.env"
      [[ -f $b/DONE ]] || { printf '%-10s %3s  (incomplete)\n' "$v" "$rep"; continue; }
      read -r pmax pslow first < <(awk -v t0="$(cat "$b/t0")" '
        $2 != "ERR" { if ($2 > m) m = $2; if ($2 >= 0.5) { n++; if (!f) f = $1 - t0 } }
        $2 == "ERR" { n++; if (!f) f = $1 - t0 }
        END { printf "%.3f %d %s\n", m, n, (f ? sprintf("%.0f", f) : "-") }' "$b/probe.txt")
      read -r idle at crq srq < <(awk -v t0="$(cat "$b/t0")" '
        !/^#/ && $6 > m { m=$6; t=$1-t0; c=$3; s=$10 } END { printf "%d %.0f %d %d\n", m, t, c, s }' "$b/conn.tsv" 2>/dev/null || echo "- - - -")
      read -r off st < <(awk '/ off [0-9]+ ms /{ for (i=1;i<=NF;i++) { if ($i=="off") d=$(i+1)+0; if ($i=="prev_state") p=$(i+1) }
        if (d < 60000 && d > m) { m=d; s=p } } END { printf "%d %s\n", m, (s=="" ? "-" : s) }' "$b/offcpu.txt" 2>/dev/null || echo "- -")
      mx=$(kv_get "$e" MAX_MS)
      printf '%-10s %3s %8s %8s %9s %6s | %9s %6s %5s | %7s %5s %7s %7s | %6s %2s\n' "$v" "$rep" "$(kv_get "$e" P99_MS)" "$(kv_get "$e" P999_MS)" \
        "$mx" "$(awk -v m="$mx" 'BEGIN{print (m>=900) ? "YES" : "-"}')" "$pmax" "$pslow" "$first" \
        "${idle:--}" "${at:--}" "${crq:--}" "${srq:--}" "${off:--}" "${st:--}"
    done
  done
  echo
  for v in "${VLIST[@]}"; do
    n=0; s=0
    for (( rep=1; rep<=REPS; rep++ )); do
      e="$D/raw/${v}_r${rep}/wl.env"; [[ -f $e ]] || continue
      n=$((n+1)); gt "$(kv_get "$e" MAX_MS)" 899 && s=$((s+1))
    done
    echo "$v: $s of $n runs stalled"
  done
} > "$D/report.txt"
cat "$D/report.txt"
