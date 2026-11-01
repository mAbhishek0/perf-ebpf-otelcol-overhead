#!/usr/bin/env bash
# run_tests.sh — logic tests that need no root and no hardware:  bash common/tests/run_tests.sh
# Covers lib.sh helpers, the nginx plugin's pure functions, wl_parse against a
# fixture, sample_stop's summary maths on a synthetic samples.tsv, and
# collect.sh end to end on a fake results dir. A green run means the logic is
# right, not that the pipeline works on hardware. The wrk2 fixture is
# SYNTHETIC until replaced with real laptop output.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAPTOP_ROOT="$(cd "$HERE/../.." && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
LOG_TAG=test
for f in sample cooldown collect; do source "$LAPTOP_ROOT/common/$f.sh"; done
source "$LAPTOP_ROOT/nginx-wrk2/workload.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
NPASS=0 NFAIL=0
ok()   { NPASS=$((NPASS+1)); }
bad()  { NFAIL=$((NFAIL+1)); printf 'FAIL: %s\n' "$*"; }
t_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1: expected '$2' got '$3'"; fi; }
t_near() { if awk -v e="$2" -v a="$3" 'BEGIN{ d=e-a; if (d<0) d=-d; exit !(d<0.001) }'; then ok; else bad "$1: expected ~$2 got '$3'"; fi; }
t_die() { local d=$1; shift; if ( "$@" ) >/dev/null 2>&1; then bad "$d: expected failure"; else ok; fi; }
t_ok()  { local d=$1; shift; if ( "$@" ) >/dev/null 2>&1; then ok; else bad "$d: expected success"; fi; }

# --- level_rate ---
LADDER="1:5000 2:10000 3:20000"
t_eq "level 2" 10000 "$(level_rate 2)"
t_eq "level 1" 5000 "$(level_rate 1)"
t_eq "R literal" 7500 "$(level_rate R7500)"
t_die "unknown level" level_rate 9

# --- run_id ---
t_eq "run_id" "L_nginx_perf_narrow_E2_try1_B3" "$(run_id nginx perf narrow 2 1 B3)"

# --- seeded_shuffle ---
a=$(seeded_shuffle 42 1 2 3 4 5 6); b=$(seeded_shuffle 42 1 2 3 4 5 6)
t_eq "shuffle deterministic" "$a" "$b"
t_eq "shuffle permutation" "1 2 3 4 5 6 " "$(sort <<<"$a" | tr '\n' ' ')"

# --- pct_diff / gt ---
t_eq "pct_diff" 9.5238 "$(pct_diff 100 110)"
t_eq "pct_diff symmetric" "$(pct_diff 110 100)" "$(pct_diff 100 110)"
t_eq "pct_diff equal" 0.0000 "$(pct_diff 5 5)"
# --- rel_spread (p99 drift calibration) ---
t_eq "rel_spread" 20.0000 "$(rel_spread 0.9 1.0 1.1)"
t_eq "rel_spread flat" 0.0000 "$(rel_spread 2 2 2)"
t_eq "rel_spread zero mean" 0.0000 "$(rel_spread 0 0)"
t_eq "pct_diff zeros" 0 "$(pct_diff 0 0)"
t_ok "gt true" gt 2 1
t_die "gt false" gt 1 2
t_die "gt equal" gt 1 1

# --- kv ---
kf="$T/kv.env"; : > "$kf"
kv_put "$kf" A hello; kv_put "$kf" B "two words"; kv_put "$kf" C "it's"
t_eq "kv A" hello "$(kv_get "$kf" A)"
t_eq "kv B" "two words" "$(kv_get "$kf" B)"
t_eq "kv quote stripped" its "$(kv_get "$kf" C)"
t_die "kv missing key" kv_get "$kf" ZZZ
t_die "kv missing file" kv_get "$T/nope.env" A

# --- nginx plugin pure functions (masks are max-CPU+1 bits wide, CPU 0 rightmost) ---
t_eq "affinity 4 workers" "0000001 0000100 0010000 1000000" \
  "$(WORKLOAD_CPUS=0,2,4,6 NGINX_WORKERS=4 _affinity_masks)"
t_eq "affinity 2 workers" "0000001 0000100" \
  "$(WORKLOAD_CPUS=0,2,4,6 NGINX_WORKERS=2 _affinity_masks)"
t_eq "to_ms us" 0.593000 "$(_to_ms 593.00us)"
t_eq "to_ms ms" 2.100000 "$(_to_ms 2.1ms)"
t_eq "to_ms s" 1750.000000 "$(_to_ms 1.75s)"
t_die "to_ms minutes" _to_ms 5m

# --- wl_parse against the fixture ---
pb="$T/parse"; mkdir -p "$pb"; cp "$HERE/fixtures/wrk2_L.txt" "$pb/workload.out"
wl_parse "$pb"
t_eq "parse throughput" 9983.37 "$(kv_get "$pb/wl.env" THROUGHPUT)"
t_eq "parse p50" 1.020000 "$(kv_get "$pb/wl.env" P50_MS)"
t_eq "parse p99" 3.410000 "$(kv_get "$pb/wl.env" P99_MS)"
t_eq "parse p999" 6.840000 "$(kv_get "$pb/wl.env" P999_MS)"
t_eq "parse errors" 3 "$(kv_get "$pb/wl.env" ERRORS)"
printf 'garbage\n' > "$pb/workload.out"
t_die "parse garbage" wl_parse "$pb"

# --- sample_stop summary on a synthetic samples.tsv (2 workload CPUs) ---
# cols: epoch tracer gen energy temp irq tstale gstale | busy total x2 | freq x2
mk_samples() {  # mk_samples BUNDLE NROWS
  local b=$1 n=$2 i
  local -a rows=(
    $'100.0\tNA\tNA\t1000000\t50\t1000\t0\t0\t100\t1000\t100\t1000\t2900000\t2900000'
    $'101.0\tNA\t50\t3000000\t55\t1500\t0\t0\t300\t1500\t200\t1500\t2950000\t2900000'
    $'102.0\tNA\t150\t5000000\t60\t2000\t0\t0\t600\t2000\t300\t2000\t2900000\t2900000')
  mkdir -p "$b/samples"
  { echo '# header'; for (( i=0; i<n; i++ )); do echo "${rows[$i]}"; done; } > "$b/samples/samples.tsv"
  echo 262143328850 > "$b/samples/rapl_range"
  : > "$b/cooldown.env"; kv_put "$b/cooldown.env" TEMP_START_C 40
}
stop_with_fake_sampler() {  # a sleeping stand-in for the loop, killed by sample_stop
  WORKLOAD_CPUS="0,2"
  sleep 300 & echo $! > "$1/pids.sampler"
  sample_stop "$1"
}
sb="$T/samp3"; mk_samples "$sb" 3
t_ok "sample_stop 3 rows" stop_with_fake_sampler "$sb"
se="$sb/samples/summary.env"
t_near "busy pct" 35 "$(kv_get "$se" BUSY_PCT_WORKLOAD)"
t_eq "freq min" 2900000 "$(kv_get "$se" FREQ_MIN_KHZ)"
t_eq "freq max" 2950000 "$(kv_get "$se" FREQ_MAX_KHZ)"
t_near "watts" 2 "$(kv_get "$se" PKG_WATTS_MEAN)"
t_eq "temp start" 40 "$(kv_get "$se" TEMP_START_C)"
t_eq "temp max" 60 "$(kv_get "$se" TEMP_MAX_C)"
t_eq "tracer NA" NA "$(kv_get "$se" TRACER_CPU_CORES)"
t_near "loadgen" "$(calc "100/$(getconf CLK_TCK)")" "$(kv_get "$se" LOADGEN_CPU_CORES)"
t_eq "irq delta" 1000 "$(kv_get "$se" IRQ_WORKLOAD_DELTA)"
t_eq "samples" 3 "$(kv_get "$se" SAMPLES)"
t_eq "freq verdict" ok "$(kv_get "$se" FREQ_VERDICT)"
sb1="$T/samp1"; mk_samples "$sb1" 1
t_die "sample_stop 1 row dies" stop_with_fake_sampler "$sb1"

# --- collect end to end on a fake results dir ---
RD="$T/results"; mkdir -p "$RD/raw"
LADDER="1:5000"
mk_bundle() {  # mk_bundle ROLE — every key of every column, in the file collect reads it from
  local role=$1 id b col name src key val traced=0
  [[ $role == B* ]] && traced=1
  id=$(run_id nginx perf narrow 1 1 "$role"); b="$RD/raw/$id"; mkdir -p "$b/samples"
  for col in "${CSV_COLUMNS[@]}"; do
    IFS=: read -r name src key <<<"$col"
    if [[ $src == mech && $traced == 0 ]]; then continue; fi
    case $key in
      RUN_ID) val=$id ;; ROLE) val=$role ;; TRACED) val=$traced ;;
      *) val="v_$key" ;;
    esac
    kv_put "$b/$(_col_file "$src")" "$key" "$val"
  done
  touch "$b/DONE"
}
for r in W1 A1 B1 A2; do mk_bundle "$r"; done
vf="$RD/raw/$(run_id nginx perf narrow 1 1 X)"; vf="${vf%_try1_X}_try1.verdict"
kv_put "$vf" VERDICT ok
collect nginx perf "$RD" >/dev/null 2>&1
csv="$RD/nginx_perf.csv"
t_eq "csv exists" yes "$([[ -f $csv ]] && echo yes || echo no)"
t_eq "csv lines (header + 3)" 4 "$(wc -l < "$csv" | tr -d ' ')"
t_eq "csv header start" '"run_id","platform","workload","mechanism"' "$(head -1 "$csv" | cut -d, -f1-4)"
t_eq "csv header cols" "${#CSV_COLUMNS[@]}" "$(head -1 "$csv" | awk -F'","' '{print NF}')"
t_eq "no warm-up row" 0 "$(grep -c '_W1' "$csv")"
t_eq "untraced mech NA" 4 "$(grep '_A1' "$csv" | grep -o '"NA"' | wc -l | tr -d ' ')"
sed -i '/^P99_MS=/d' "$RD/raw/$(run_id nginx perf narrow 1 1 B1)/wl.env"
t_die "collect dies on missing key" collect nginx perf "$RD"

printf '%s passed, %s failed\n' "$NPASS" "$NFAIL"
(( NFAIL == 0 ))
