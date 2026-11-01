# sample.sh — 1 Hz background sampler for the measured window. Sourced;
# requires lib.sh, config, and cooldown.env in the bundle (cooldown_wait).
#
# sample_start BUNDLE  launches one loop pinned to GEN_CPUS (PID in
#   BUNDLE/pids.sampler) appending to BUNDLE/samples/samples.tsv.
# sample_stop BUNDLE   kills it, then writes BUNDLE/samples/summary.env.
#
# Row layout (tab-separated, '#' header skipped):
#   1 epoch  2 tracer_ticks  3 gen_ticks  4 energy_uj  5 temp_c  6 irq_total
#   7 tracer_stale  8 gen_stale   then per workload CPU: busy total (2n cols),
#   then per workload CPU: scaling_cur_freq (n cols).
# A row is written only after every value in it was read. If a tracer/gen PID
# can no longer be read (process gone), that tick reuses the previous row's
# value and the stale flag is 1; the summary only uses rows with flag 0. Tracer
# ticks are NA when BUNDLE/pids.tracer is absent (baseline); gen ticks are NA
# while BUNDLE/pids.gen is absent (wrk2 not started yet / already exited).
# Tracer CPU comes from the tracer PIDs' stat, never from the cgroup.

SAMPLE_MAX_TICKS=7200   # the loop is bounded: an orphan dies after 2 h

_sample_ticks() {  # _sample_ticks PIDFILE -> sum of utime+stime; 1 if any PID unreadable
  local pid s sum=0 n=0
  local -a f
  while read -r pid; do
    [[ -n $pid ]] || continue
    s=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    [[ -n $s ]] || return 1
    s=${s##*) }                      # comm may contain spaces; fields restart after ')'
    read -ra f <<<"$s"               # f[0]=state (field 3) => utime=f[11], stime=f[12]
    [[ -n ${f[12]:-} ]] || return 1
    sum=$(( sum + f[11] + f[12] )); n=$(( n + 1 ))
  done < "$1" || return 1
  (( n > 0 )) || return 1
  printf '%s' "$sum"
}

_sample_irq() {  # sum of interrupt counts on the workload CPUs; header lists online CPUs only
  awk -v cpus="$WORKLOAD_CPUS" '
    NR==1 { for (i=1;i<=NF;i++) { c=$i; sub(/^CPU/,"",c); col[c]=i+1 }
            n=split(cpus,a,","); for (i=1;i<=n;i++) if (!(a[i] in col)) bad=1; next }
    { for (i=1;i<=n;i++) { v=$(col[a[i]]); if (v ~ /^[0-9]+$/) s+=v } }
    END { if (bad) exit 1; printf "%d", s }' /proc/interrupts
}

_sample_stat() {  # "busy total" per workload CPU, in WORKLOAD_CPUS order; busy = total - idle - iowait
  awk -v cpus="$WORKLOAD_CPUS" '
    BEGIN { n=split(cpus,a,","); for (i=1;i<=n;i++) w["cpu" a[i]]=1 }
    ($1 in w) { t=0; for (i=2;i<=9;i++) t+=$i; tt[$1]=t; b[$1]=t-$5-$6 }
    END { for (i=1;i<=n;i++) { k="cpu" a[i]; if (!(k in b)) exit 1; printf "%d %d%s", b[k], tt[k], (i<n?" ":"") } }' /proc/stat
}

_sample_loop() {
  local b=$1 out="$1/samples/samples.tsv" i now stat irq energy temp c f fr tk gk ts gs
  local prev_t="" prev_g="" tab=$'\t' ok
  taskset -cp "$GEN_CPUS" "$BASHPID" >/dev/null 2>&1
  for (( i=0; i<SAMPLE_MAX_TICKS; i++ )); do
    ok=1
    now=$(date +%s.%N)
    stat=$(_sample_stat) || ok=0
    irq=$(_sample_irq) || ok=0
    energy=$(cat /sys/class/powercap/intel-rapl:0/energy_uj 2>/dev/null) || ok=0
    temp=$(pkg_temp_c)
    fr=""
    for c in ${WORKLOAD_CPUS//,/ }; do
      f=$(cat "/sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq" 2>/dev/null) || f=""
      [[ -n $f ]] || ok=0
      fr+="${tab}${f}"
    done
    ts=0; gs=0; tk=NA; gk=NA
    if (( ok )) && [[ -f $b/pids.tracer ]]; then
      if tk=$(_sample_ticks "$b/pids.tracer"); then prev_t=$tk
      elif [[ -n $prev_t ]]; then tk=$prev_t; ts=1
      else ok=0; fi
    fi
    if (( ok )) && [[ -f $b/pids.gen ]]; then
      if gk=$(_sample_ticks "$b/pids.gen"); then prev_g=$gk
      elif [[ -n $prev_g ]]; then gk=$prev_g; gs=1
      else gk=NA; gs=1; fi
    fi
    if (( ok )); then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s%s\n' "$now" "$tk" "$gk" "$energy" "$temp" "$irq" \
        "$ts" "$gs" "${stat// /$tab}" "$fr" >> "$out"
    fi
    sleep 1
  done
}

sample_start() {
  local b=$1 n
  mkdir -p "$b/samples"
  n=$(wc -w <<<"${WORKLOAD_CPUS//,/ }")
  [[ -r /sys/class/powercap/intel-rapl:0/energy_uj ]] || die "RAPL energy_uj unreadable"
  cat /sys/class/powercap/intel-rapl:0/max_energy_range_uj > "$b/samples/rapl_range" 2>/dev/null \
    || die "RAPL max_energy_range_uj unreadable"
  printf '# epoch tracer_ticks gen_ticks energy_uj temp_c irq tracer_stale gen_stale busy/total x%s freq x%s\n' "$n" "$n" \
    > "$b/samples/samples.tsv"
  _sample_loop "$b" &
  echo $! > "$b/pids.sampler"
}

sample_stop() {
  local b=$1
  local pid i st s="$b/samples/samples.tsv" e="$b/samples/summary.env"
  local n out k v clk wrap lo hi fmin fmax hastr=0
  pid=$(cat "$b/pids.sampler" 2>/dev/null) || die "no $b/pids.sampler"
  kill "$pid" 2>/dev/null || true
  for (( i=0; i<25; i++ )); do          # bounded: 5 s, then SIGKILL
    st=$(awk '{ s=$0; sub(/^.*\) /,"",s); print substr(s,1,1) }' "/proc/$pid/stat" 2>/dev/null || true)
    if [[ -z $st || $st == Z ]]; then break; fi
    sleep 0.2
  done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  [[ -f $s ]] || die "no samples file $s"
  [[ -f $b/cooldown.env ]] || die "no $b/cooldown.env"
  [[ -f $b/pids.tracer ]] && hastr=1
  wrap=$(cat "$b/samples/rapl_range" 2>/dev/null) || die "no rapl_range in $b/samples"
  clk=$(getconf CLK_TCK)
  n=$(wc -w <<<"${WORKLOAD_CPUS//,/ }")
  out=$(awk -F'\t' -v n="$n" -v clk="$clk" -v wrap="$wrap" -v hastr="$hastr" '
    /^#/ { next }
    NF != 8+3*n { next }
    { r++; ep[r]=$1; en[r]=$4; tp[r]=$5; ir[r]=$6
      for (k=0;k<n;k++) { bz[r,k]=$(9+2*k); tz[r,k]=$(10+2*k); fq=$(9+2*n+k)+0
        if (!fset || fq<fmin) fmin=fq; if (!fset || fq>fmax) fmax=fq; fset=1 }
      if (r==1 || tp[r]+0>tmax) tmax=tp[r]+0
      if ($7==0 && $2!="NA") { if (!tf) tf=r; tl=r; tk[r]=$2 }
      if ($8==0 && $3!="NA") { if (!gf) gf=r; gl=r; gk[r]=$3 }
    }
    END {
      if (r<2) { print "ERR fewer than 2 complete samples (" r+0 ")"; exit 1 }
      dt=ep[r]-ep[1]; if (dt<=0) { print "ERR non-positive window"; exit 1 }
      s=0
      for (k=0;k<n;k++) { d=tz[r,k]-tz[1,k]; if (d<=0) { print "ERR no jiffies on cpu index " k; exit 1 }
        s+=100*(bz[r,k]-bz[1,k])/d }
      printf "BUSY_PCT_WORKLOAD %.4f\n", s/n
      printf "FREQ_MIN_KHZ %d\nFREQ_MAX_KHZ %d\n", fmin, fmax
      de=en[r]-en[1]; if (de<0) de+=wrap
      printf "PKG_WATTS_MEAN %.4f\n", de/1e6/dt
      printf "TEMP_MAX_C %d\n", tmax
      if (hastr+0) {
        if (tf==0 || tl<=tf) { print "ERR fewer than 2 valid tracer samples"; exit 1 }
        printf "TRACER_CPU_CORES %.4f\n", (tk[tl]-tk[tf])/clk/(ep[tl]-ep[tf])
      } else print "TRACER_CPU_CORES NA"
      if (gf==0 || gl<=gf) { print "ERR fewer than 2 samples with the load generator present"; exit 1 }
      printf "LOADGEN_CPU_CORES %.4f\n", (gk[gl]-gk[gf])/clk/(ep[gl]-ep[gf])
      printf "IRQ_WORKLOAD_DELTA %d\nSAMPLES %d\n", ir[r]-ir[1], r
    }' "$s") || die "sample summary failed for $b: $out"
  : > "$e"
  while read -r k v; do kv_put "$e" "$k" "$v"; done <<<"$out"
  kv_put "$e" TEMP_START_C "$(kv_get "$b/cooldown.env" TEMP_START_C)"
  kv_put "$e" CLK_TCK "$clk"
  fmin=$(kv_get "$e" FREQ_MIN_KHZ); fmax=$(kv_get "$e" FREQ_MAX_KHZ)
  lo=$(calc "$CLOCK_BASE_KHZ*(1-$CLOCK_TOL_PCT/100)"); hi=$(calc "$CLOCK_BASE_KHZ*(1+$CLOCK_TOL_PCT/100)")
  if ! gt "$lo" "$fmin" && ! gt "$fmax" "$hi"; then kv_put "$e" FREQ_VERDICT ok
  else kv_put "$e" FREQ_VERDICT out_of_band; fi
}
