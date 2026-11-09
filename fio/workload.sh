# workload.sh — fio workload plugin. Sourced. Shared by the perf, ebpf and
# collector pairs so all three drive fio identically.
#
# Contract (as nginx-wrk2/workload.sh): wl_preflight, wl_start BUNDLE,
#   wl_ramp RATE BUNDLE, wl_measure RATE BUNDLE, wl_stop, wl_parse BUNDLE;
#   plus the optional hooks wl_cell_prep, wl_provenance, wl_schema_json,
#   wl_csv_columns.
#
# Decision 3.3 (PLAN.md): 4K random reads, O_DIRECT, rate set with
# rate_iops, on a file fio/prepare.sh wrote once. RATE is total IOPS, split
# evenly over FIO_NUMJOBS jobs, one job per workload CPU.
#
# fio is both the load and the workload, so ONE fio process spans the ramp
# and the measured window: a tracer needs a live target between them, as it
# has nginx's workers. The job file has two stonewalled groups:
#   ramp     RAMP_S at the target rate (untraced, discarded)
#   measure  STEADY_S at the target rate. Each job first runs gate.sh
#            (exec_prerun): it drops ready.<pid> and waits for BUNDLE/go.
# wl_ramp returns when every measure job waits at the gate (its threads
# exist, so perf -p sees them); run_one attaches the tracer; wl_measure
# touches go. fio_parse.py refuses a run whose measured runtime is more than
# 2 % from STEADY_S, so the gate can never shorten a window unnoticed.
#
# fio runs in the transient scope FIO_UNIT under BENCH_SLICE; that cgroup is
# workload_cpu_cores, as nginx's container scope is. A scope vanishes when
# its last process exits, but run_one reads the cgroup AFTER the window, so
# the wrapper starts `sleep 3600` in the scope before it execs fio; wl_stop
# stops the scope. The sleep sits on OS_CPUS (inherited affinity) and uses
# no CPU.
#
# fio is its own generator: pids.gen holds fio's PID during the window, so
# loadgen_cpu_cores is fio's process CPU, a cross-check of
# workload_cpu_cores, not a separate generator.
#
# pilot.sh applies --set overrides AFTER this file is sourced, so every value
# derived from FIO_NUMJOBS / FIO_IODEPTH is computed inside a function.

WL_NAME="fio"
WL_DIR="${LAPTOP_ROOT}/fio"
source "$WL_DIR/fio.env"
[[ -f "$WL_DIR/pilot.env" ]] && source "$WL_DIR/pilot.env"   # LADDER, FIO_NUMJOBS, FIO_IODEPTH
FIO_NUMJOBS=${FIO_NUMJOBS:-4}
FIO_IODEPTH=${FIO_IODEPTH:-32}
WL_KNOBS="FIO_NUMJOBS FIO_IODEPTH"                          # pilot.sh --set
WL_PILOT_RATES="10000,25000,50000,100000,150000,200000"    # pilot.sh default --rates (IOPS)
FIO_DEV=${FIO_DEV:-}

# _fio_device -> whole-disk name under FIO_DIR (nvme0n1p6 -> nvme0n1)
_fio_device() {
  local src pk
  src=$(findmnt -no SOURCE --target "$FIO_DIR") || return 1
  pk=$(lsblk -no PKNAME "$src" 2>/dev/null || true)
  pk=${pk%%$'\n'*}
  printf '%s' "${pk:-$(basename "$src")}"
}

_fio_per_job_rate() {  # TOTAL_IOPS -> per-job rate_iops; dies unless it splits evenly
  [[ $1 =~ ^[1-9][0-9]*$ ]] && (( $1 % FIO_NUMJOBS == 0 )) \
    || die "rate '$1' IOPS does not split evenly over FIO_NUMJOBS=$FIO_NUMJOBS jobs"
  printf '%s' $(( $1 / FIO_NUMJOBS ))
}

_fio_jobfile() {  # RATE BUNDLE -> fio job file on stdout
  local per
  per=$(_fio_per_job_rate "$1") || return 1
  cat <<EOF
# fio job — rendered per run by fio/workload.sh; do not edit.
[global]
ioengine=${FIO_ENGINE}
direct=1
rw=${FIO_RW}
bs=${FIO_BS}
filename=${FIO_FILE}
size=${FIO_FILE_BYTES}
thread
numjobs=${FIO_NUMJOBS}
iodepth=${FIO_IODEPTH}
rate_iops=${per}
randrepeat=1
randseed=${FIO_RANDSEED}
norandommap
time_based
group_reporting
cpus_allowed=${WORKLOAD_CPUS}
cpus_allowed_policy=split
lat_percentiles=1
clat_percentiles=0
percentile_list=50:99:99.9

[ramp]
runtime=${RAMP_S}

[measure]
stonewall
runtime=${STEADY_S}
exec_prerun=/bin/sh $2/gate.sh
EOF
}

_fio_gate() {  # BUNDLE -> gate.sh on stdout (POSIX sh: fio runs it via system(3))
  cat <<EOF
#!/bin/sh
# gate.sh — fio exec_prerun for each measure job: say "waiting", then wait
# for the harness's go. The marker holds its arrival time in ns (GATE_WAIT_S). Bounded, so a dead harness cannot leave fio hanging.
date +%s%N > "$1/ready.\$\$"
n=0
while [ ! -e "$1/go" ]; do
  n=\$((n + 1))
  [ \$n -le $(( FIO_GATE_TIMEOUT_S * 20 )) ] || exit 1
  sleep 0.05
done
EOF
}

_fio_ready_count() {  # BUNDLE -> number of measure jobs waiting at the gate
  local f n=0
  for f in "$1"/ready.*; do [[ -e $f ]] && n=$((n + 1)); done
  echo "$n"
}
_fio_ready_or_dead() {  # BUNDLE PID
  (( $(_fio_ready_count "$1") >= FIO_NUMJOBS )) || ! kill -0 "$2" 2>/dev/null
}

# _fio_gate_wait_s BUNDLE GO_NS -> seconds from the oldest ready.* marker to GO_NS.
# Dies on a missing or unparseable marker: GATE_WAIT_S must never be blank.
_fio_gate_wait_s() {
  local oldest
  oldest=$(cat "$1"/ready.* 2>/dev/null | sort -n | head -n 1) || true   # no marker: the check below dies with the clear message
  [[ $oldest =~ ^[0-9]{16,}$ ]] || die "no usable ready.* timestamp in $1 (got '$oldest')"
  [[ $2 =~ ^[0-9]{16,}$ ]] && (( $2 >= oldest )) || die "bad go time '$2' (oldest ready $oldest)"
  awk -v d=$(( $2 - oldest )) 'BEGIN{ printf "%.3f", d / 1e9 }'
}

# _fio_check_rates -> dies unless every rate this run will use splits evenly
# over FIO_NUMJOBS. Rates come from the frozen LADDER ("level:rate" pairs, as
# level_rate reads them), pilot.sh's RATES and run_workload.sh's CAPACITY_RATES;
# read at call time, after pilot.sh --set has changed FIO_NUMJOBS.
_fio_check_rates() {
  local r p
  for p in ${LADDER:-}; do
    r=${p#*:}
    [[ $r =~ ^[1-9][0-9]*$ ]] && (( r % FIO_NUMJOBS == 0 )) \
      || die "ladder rate '$r' IOPS (level ${p%%:*}) does not split evenly over FIO_NUMJOBS=$FIO_NUMJOBS jobs"
  done
  for r in $(tr ',' ' ' <<<"${RATES:-} ${CAPACITY_RATES:-}"); do
    [[ $r =~ ^[1-9][0-9]*$ ]] && (( r % FIO_NUMJOBS == 0 )) \
      || die "rate '$r' IOPS does not split evenly over FIO_NUMJOBS=$FIO_NUMJOBS jobs"
  done
}

wl_preflight() {
  local v dev sched ncpu
  cap v fio --version
  [[ $v == "$FIO_VERSION_EXPECTED" ]] && pf_ok "$v" || pf_fail "fio is '$v', pinned $FIO_VERSION_EXPECTED"
  cap v fio --enghelp
  [[ $v == *"$FIO_ENGINE"* ]] && pf_ok "fio engine $FIO_ENGINE" || pf_fail "fio lacks the $FIO_ENGINE engine"
  if [[ -f $FIO_FILE && -f $FIO_FILE.env && "$(stat -c %s "$FIO_FILE")" == "$FIO_FILE_BYTES" ]]; then
    pf_ok "data file $FIO_FILE ($FIO_FILE_BYTES bytes, prepared $(kv_get "$FIO_FILE.env" PREPARED_AT))"
  else
    pf_fail "$FIO_FILE missing or not $FIO_FILE_BYTES bytes — run: sudo bash fio/prepare.sh"
  fi
  dev=$(_fio_device 2>/dev/null || true)
  [[ $dev == "$FIO_DEVICE_EXPECTED" ]] && pf_ok "fio target on $dev" \
    || pf_fail "FIO_DIR $FIO_DIR is on '$dev', expected $FIO_DEVICE_EXPECTED"
  FIO_DEV=$dev
  [[ "$(cat "/sys/block/$dev/queue/rotational" 2>/dev/null)" == 0 ]] && pf_ok "$dev non-rotational" \
    || pf_fail "$dev rotational or unreadable"
  sched=$(cat "/sys/block/$dev/queue/scheduler" 2>/dev/null || echo unreadable)
  [[ $sched == *"[none]"* ]] && pf_ok "$dev scheduler none" || pf_fail "$dev scheduler '$sched' (probed: [none])"
  if pgrep -x fio >/dev/null 2>&1; then pf_fail "a fio process is already running"; else pf_ok "no fio running"; fi
  if systemctl is-active --quiet "$FIO_UNIT.scope" 2>/dev/null; then pf_fail "$FIO_UNIT.scope is active (leftover run?)"; fi
  command -v fstrim >/dev/null 2>&1 || pf_fail "fstrim missing (util-linux)"
  "$FIO_PYTHON" -c 'import json' >/dev/null 2>&1 && pf_ok "$FIO_PYTHON for fio_parse.py" || pf_fail "$FIO_PYTHON missing"
  ncpu=$(wc -w <<<"${WORKLOAD_CPUS//,/ }")
  (( FIO_NUMJOBS >= 1 && FIO_NUMJOBS <= ncpu && FIO_IODEPTH >= 1 )) \
    && pf_ok "fio $FIO_NUMJOBS jobs x iodepth $FIO_IODEPTH" \
    || pf_fail "FIO_NUMJOBS=$FIO_NUMJOBS / FIO_IODEPTH=$FIO_IODEPTH (jobs must be 1..$ncpu: one per workload CPU)"
  _fio_check_rates
  pf_ok "every ladder / pilot / capacity rate divides by $FIO_NUMJOBS jobs"
}

wl_start() {
  local b=$1
  [[ -n $FIO_DEV ]] || FIO_DEV=$(_fio_device) || die "cannot find the disk under $FIO_DIR"
  systemctl stop "$FIO_UNIT.scope" >/dev/null 2>&1 || true   # a leftover would make systemd-run fail
  rm -f "$b"/ready.* "$b/go"
  _fio_gate "$b" > "$b/gate.sh"
  sh -n "$b/gate.sh" || die "gate.sh does not parse"
}

wl_ramp() {
  local rate=$1 b=$2 pid cg
  _fio_jobfile "$rate" "$b" > "$b/fio.job" || die "cannot render $b/fio.job"
  # systemd-run --scope, sh and taskset all exec, so $! is fio's own PID.
  systemd-run --quiet --collect --scope --slice="$BENCH_SLICE" --unit="$FIO_UNIT" -- \
    sh -c 'cd "$2" || exit 97; sleep 3600 & exec taskset -c "$1" fio --output-format=json --output=fio.json fio.job' \
    fio-wrapper "$WORKLOAD_CPUS" "$b" > "$b/fio.log" 2>&1 &
  pid=$!
  echo "$pid" > "$b/fio_pid"
  echo "$pid" > "$b/target_pids"
  wait_for $(( RAMP_S + 60 )) gate _fio_ready_or_dead "$b" "$pid" || true
  kill -0 "$pid" 2>/dev/null || die "fio exited during the ramp (see $b/fio.log)"
  (( $(_fio_ready_count "$b") == FIO_NUMJOBS )) \
    || die "$(_fio_ready_count "$b")/$FIO_NUMJOBS measure jobs reached the gate within $(( RAMP_S + 60 ))s (see $b/fio.log)"
  [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == fio ]] || die "pid $pid is '$(cat "/proc/$pid/comm" 2>/dev/null)', not fio"
  cg=$(awk -F'::' '/^0::/{print $2}' "/proc/$pid/cgroup")
  [[ $cg == */"$FIO_UNIT.scope" && -f /sys/fs/cgroup$cg/cpu.stat ]] || die "fio is in cgroup '$cg', not $FIO_UNIT.scope"
  echo "/sys/fs/cgroup$cg" > "$b/cgroup_path"
}

wl_measure() {
  local b=$2 pid rc=0 t_go
  pid=$(cat "$b/fio_pid")
  echo "$pid" > "$b/pids.gen"          # fio is its own generator (header)
  cat "/sys/block/$FIO_DEV/stat" > "$b/diskstat_before.txt"
  t_go=$(date +%s%N)
  : > "$b/go"
  _fio_gate_wait_s "$b" "$t_go" > "$b/gate_wait_s"   # dies, rather than leave a blank
  wait "$pid" || rc=$?
  cat "/sys/block/$FIO_DEV/stat" > "$b/diskstat_after.txt"
  rm -f "$b/pids.gen"
  (( rc == 0 )) || die "fio exited $rc (see $b/fio.log)"
}

wl_stop() { systemctl stop "$FIO_UNIT.scope" >/dev/null 2>&1 || true; }

wl_parse() {
  local b=$1 e="$1/wl.env"
  "$FIO_PYTHON" -I "$WL_DIR/fio_parse.py" "$b/fio.json" "$STEADY_S" > "$e.partial" 2> "$b/fio_parse.err" \
    || die "cannot parse $b/fio.json: $(cat "$b/fio_parse.err")"
  # Whole-disk reads and writes completed during the window (/sys/block/<dev>/stat
  # fields 1 and 5): fio's I/O plus anyone else's, e.g. the harness's own writes.
  local rd wr gw
  rd=$(awk 'NR==FNR{r=$1; next} {print $1-r}' "$b/diskstat_before.txt" "$b/diskstat_after.txt")
  wr=$(awk 'NR==FNR{w=$5; next} {print $5-w}' "$b/diskstat_before.txt" "$b/diskstat_after.txt")
  [[ $rd =~ ^[0-9]+$ ]] || die "disk reads delta '$rd' is not a non-negative integer (see $b/diskstat_*.txt)"
  [[ $wr =~ ^[0-9]+$ ]] || die "disk writes delta '$wr' is not a non-negative integer (see $b/diskstat_*.txt)"
  gw=$(cat "$b/gate_wait_s" 2>/dev/null || true)
  [[ $gw =~ ^[0-9]+\.[0-9]+$ ]] || die "no gate wait in $b/gate_wait_s (got '$gw')"
  kv_put "$e.partial" FIO_DISK_READS_DELTA "$rd"
  kv_put "$e.partial" FIO_DISK_WRITES_DELTA "$wr"
  kv_put "$e.partial" GATE_WAIT_S "$gw"
  mv "$e.partial" "$e"
}

# Before each bracket try (common/bracket.sh): trim the filesystem's free
# space, then idle so the drive finishes that work before the warm-up.
wl_cell_prep() {
  local f=$1 mnt out
  (( FIO_CELL_TRIM )) || return 0
  mnt=$(findmnt -no TARGET --target "$FIO_DIR") || die "no mount point for $FIO_DIR"
  out=$(fstrim -v "$mnt" 2>&1) || die "fstrim $mnt failed: $out"
  sleep "$FIO_CELL_IDLE_S"
  : > "$f.partial"
  kv_put "$f.partial" FSTRIM "$out"
  kv_put "$f.partial" IDLE_S "$FIO_CELL_IDLE_S"
  mv "$f.partial" "$f"
}

_fio_irq_config() {  # the CONFIG_IRQ_TIME_ACCOUNTING line, or "unknown"
  local line
  line=$(grep -E -m1 '^(# )?CONFIG_IRQ_TIME_ACCOUNTING([= ]|$)' "/boot/config-$(uname -r)" 2>/dev/null) || true
  echo "${line:-unknown}"
}
_fio_nvme_ps_latency() {
  local v
  v=$(cat /sys/module/nvme_core/parameters/default_ps_max_latency_us 2>/dev/null) || true
  echo "${v:-unknown}"
}

wl_provenance() {
  local f=$1 d=${FIO_DEV:-NA}
  kv_put "$f" FIO_VERSION "$(_prov_cmd fio --version)"
  kv_put "$f" FIO_FILE "$FIO_FILE"
  kv_put "$f" FIO_FILE_BYTES "$(_prov_cmd stat -c %s "$FIO_FILE")"
  if [[ -f $FIO_FILE.env ]]; then kv_put "$f" FIO_FILE_PREPARED_AT "$(kv_get "$FIO_FILE.env" PREPARED_AT)"
  else kv_put "$f" FIO_FILE_PREPARED_AT NA; fi
  kv_put "$f" FIO_DEVICE "$d"
  kv_put "$f" FIO_DEVICE_MODEL "$(_prov_cmd cat "/sys/block/$d/device/model")"
  kv_put "$f" FIO_DEVICE_FIRMWARE "$(_prov_cmd cat "/sys/block/$d/device/firmware_rev")"
  kv_put "$f" FIO_DEVICE_SCHEDULER "$(_prov_cmd cat "/sys/block/$d/queue/scheduler")"
  # IRQ time accounting decides whether interrupt time (the eBPF narrow
  # completion probe) reaches workload_cpu_cores; tsc=noirqtime turns it off at
  # run time. The NVMe power-state latency limit gates deep idle states.
  kv_put "$f" KERNEL_CONFIG_IRQ_TIME_ACCOUNTING "$(_fio_irq_config)"
  kv_put "$f" KERNEL_CMDLINE "$(_prov_cmd cat /proc/cmdline)"
  kv_put "$f" NVME_DEFAULT_PS_MAX_LATENCY_US "$(_fio_nvme_ps_latency)"
}

# fio's own CSV columns, after the shared ones (common/collect.sh _csv_cols).
# Each is "csv name:wl.env key:unit"; every value is a non-negative number.
#   fio_runtime_ms        measured group's runtime (fio_parse.py; within 2 % of STEADY_S)
#   fio_total_ios         I/Os fio completed in the measured group
#   fio_ramp_iops         IOPS of the discarded ramp group, for the record
#   fio_disk_reads_delta  whole-disk reads completed during the window, by anyone
#   fio_disk_writes_delta whole-disk writes completed during the window, by anyone
#   gate_wait_s           oldest ready.* marker to go: how long the disk sat idle
wl_csv_columns() {
  printf '%s\n' \
    'fio_runtime_ms:FIO_RUNTIME_MS:ms' \
    'fio_total_ios:FIO_TOTAL_IOS:I/Os' \
    'fio_ramp_iops:FIO_RAMP_IOPS:IOPS' \
    'fio_disk_reads_delta:FIO_DISK_READS_DELTA:completed requests' \
    'fio_disk_writes_delta:FIO_DISK_WRITES_DELTA:completed requests' \
    'gate_wait_s:GATE_WAIT_S:s'
}

wl_schema_json() {
  printf '  "fio_engine": "%s", "fio_rw": "%s", "fio_bs": "%s", "fio_numjobs": %s, "fio_iodepth": %s,\n' \
    "$FIO_ENGINE" "$FIO_RW" "$FIO_BS" "$FIO_NUMJOBS" "$FIO_IODEPTH"
  printf '  "fio_file_bytes": %s, "fio_randseed": %s, "fio_cell_trim": %s, "fio_cell_idle_s": %s,\n' \
    "$FIO_FILE_BYTES" "$FIO_RANDSEED" "$FIO_CELL_TRIM" "$FIO_CELL_IDLE_S"
}
