#!/usr/bin/env bash
# run_tests.sh — logic tests that need no root and no hardware:  bash common/tests/run_tests.sh
# Covers lib.sh helpers, the nginx plugin's pure functions, wl_parse against a
# fixture, sample_stop's summary maths on a synthetic samples.tsv, and
# collect.sh end to end on a fake results dir. A green run means the logic is
# right, not that the pipeline works on hardware. The wrk2 fixture is
# real laptop output (pilot R10000, 2026-11-01).

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
t_eq "run_id block 2" "L_b2_nginx_perf_narrow_E2_try1_B3" "$(BLOCK=2 run_id nginx perf narrow 2 1 B3)"
t_eq "run_id block 1 explicit" "L_nginx_perf_narrow_E2_try1_B3" "$(BLOCK=1 run_id nginx perf narrow 2 1 B3)"
t_eq "run_id capacity" "L_cap_nginx_perf_wide_ER44000_try1_B3" "$(CAPACITY=1 run_id nginx perf wide R44000 1 B3)"

# --- capacity_levels (run_workload.sh --capacity) ---
t_eq "capacity levels" "R40000,R44000," "$(capacity_levels 40000,44000)"
t_eq "capacity level rate" 44000 "$(level_rate "$(capacity_levels 44000 | cut -d, -f1)")"
t_die "capacity bad list" capacity_levels "40000,,44000"
t_die "capacity non-number" capacity_levels "40k"
t_die "capacity zero-led" capacity_levels "040000"
t_die "capacity repeat" capacity_levels "40000,44000,40000"

# --- block_order (block >= 2: block 1's last order, reversed) ---
bo=$(mktemp)
printf '%s\n' "2026-11-07T18:20:10+05:30 ebpf levels: 2 4 3 1 scopes: narrow,wide" \
              "2026-11-07T23:58:26+05:30 ebpf block 1 levels: 2 4 3 1 scopes: narrow,wide" > "$bo"
t_eq "block_order reversed" "1 3 4 2 " "$(block_order "$bo" 1,2,3,4, | tr '\n' ' ')"
t_eq "block_order subset" "3 2 " "$(block_order "$bo" 2,3 | tr '\n' ' ')"
t_eq "block_order no match" "" "$(block_order "$bo" 9)"
rm -f "$bo"

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
t_eq "trimmed spread ignores one stall" 15.9091 "$(rel_spread_trimmed 2.93 449.54 2.89 2.85 3.38 3.23)"
t_eq "trimmed spread small n untrimmed" 20.0000 "$(rel_spread_trimmed 0.9 1.0 1.1)"
printf 'Tcp:RetransSegs 5
Tcp:InSegs 1
' > "$T/n1"; printf 'Tcp:RetransSegs 9
' > "$T/n2"
t_eq "net_delta" 4 "$(net_delta "$T/n1" "$T/n2" Tcp:RetransSegs)"
t_eq "net_delta absent" 0 "$(net_delta "$T/n1" "$T/n2" Tcp:Nope)"
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
t_eq "parse throughput" 9989.95 "$(kv_get "$pb/wl.env" THROUGHPUT)"
t_eq "parse p50" 1.780000 "$(kv_get "$pb/wl.env" P50_MS)"
t_eq "parse p99" 3.510000 "$(kv_get "$pb/wl.env" P99_MS)"
t_eq "parse p999" 4.820000 "$(kv_get "$pb/wl.env" P999_MS)"
t_eq "parse errors" 0 "$(kv_get "$pb/wl.env" ERRORS)"
t_eq "parse max" 7.588 "$(kv_get "$pb/wl.env" MAX_MS)"
printf '  Socket errors: connect 0, read 1, write 0, timeout 3
' >> "$pb/workload.out"; : > "$pb/wl.env"; wl_parse "$pb"
t_eq "parse socket errors" 4 "$(kv_get "$pb/wl.env" ERRORS)"
printf 'garbage\n' > "$pb/workload.out"
t_die "parse garbage" wl_parse "$pb"

# --- sample_stop summary on a synthetic samples.tsv (2 workload CPUs) ---
# cols: epoch tracer gen energy temp irq tstale gstale | busy total x2 | freq x2
#       | irq dev timer ipi nmi pmi other | softirq net_rx net_tx
mk_samples() {  # mk_samples BUNDLE NROWS
  local b=$1 n=$2 i
  local -a rows=(
    $'100.0\tNA\tNA\t1000000\t50\t1000\t0\t0\t100\t1000\t100\t1000\t2900000\t2900000\t10\t20\t30\t40\t50\t60\t70\t80'
    $'101.0\tNA\t50\t3000000\t55\t1500\t0\t0\t300\t1500\t200\t1500\t2950000\t2900000\t11\t22\t33\t44\t55\t66\t77\t88'
    $'102.0\tNA\t150\t5000000\t60\t2000\t0\t0\t600\t2000\t300\t2000\t2900000\t2900000\t12\t24\t36\t48\t60\t72\t84\t96')
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
i=0; for k in IRQ_DEV IRQ_TIMER IRQ_IPI IRQ_NMI IRQ_PMI IRQ_OTHER SOFTIRQ_NET_RX SOFTIRQ_NET_TX; do
  i=$((i+1)); t_eq "split $k" "$((2*i))" "$(kv_get "$se" ${k}_DELTA)"; done
t_eq "freq verdict" ok "$(kv_get "$se" FREQ_VERDICT)"
sb1="$T/samp1"; mk_samples "$sb1" 1
t_die "sample_stop 1 row dies" stop_with_fake_sampler "$sb1"

# --- interrupt / softirq classification (/proc layout, CPUs 0,2 of 0..3) ---
WORKLOAD_CPUS="0,2"
printf '%s\n' '           CPU0       CPU1       CPU2       CPU3' \
  '  0:         10          1         20          1  IR-IO-APIC    2-edge      timer' \
  ' 42:        100          1        200          1  IR-PCI-MSI  eth0' \
  'NMI:          5          1          6          1   Non-maskable interrupts' \
  'LOC:       1000          1       2000          1   Local timer interrupts' \
  'PMI:          5          1          6          1   Performance monitoring interrupts' \
  'RES:          7          1          8          1   Rescheduling interrupts' \
  'CAL:          1          1          2          1   Function call interrupts' \
  'TLB:          3          1          4          1   TLB shootdowns' \
  'ERR:          0' 'MIS:          0' \
  'DFR:          9          1          9          1   Deferred Error APIC interrupts' > "$T/interrupts"
t_eq "irq split" "3395 330 3000 25 11 11 18" "$(_sample_irq "$T/interrupts")"
printf '%s\n' '                    CPU0       CPU1       CPU2       CPU3' \
  '          HI:          0          0          0          0' \
  '      NET_TX:          3          9          4          9' \
  '      NET_RX:        100          9        200          9' > "$T/softirqs"
t_eq "softirq net" "300 7" "$(_sample_softirq "$T/softirqs")"
grep -v NET_TX "$T/softirqs" > "$T/softirqs2"
t_die "softirq missing NET_TX" _sample_softirq "$T/softirqs2"
WORKLOAD_CPUS="0,5"
t_die "irq offline cpu" _sample_irq "$T/interrupts"

# --- perf mech_stats loss accounting (perf stubbed) ---
source "$LAPTOP_ROOT/nginx-wrk2/perf/scripts/mech.sh"
mb="$T/mech"; mkdir -p "$mb"; : > "$mb/mech.meta"
printf '%s\n' 'Aggregated stats:' '               TOTAL events:     1000' \
  '              SAMPLE events:      900' 'cpu/cycles/P stats:' '              SAMPLE events:      900' > "$mb/perf_report_stats.txt"
printf '%s\n' '' ' Summary of events:' '' ' perf (11), 24 events, 0.0%' '' ' nginx worker (12), 1000 events, 50.0%' \
  '   writev   10   0' ' wrk:2 (13), 76 events, 2.0%' 'LOST 5 events!' > "$mb/perf_trace.out"
mech_stats "$mb"
t_eq "events = samples + trace" 2000 "$(kv_get "$mb/mech.stats" MECH_EVENTS)"
t_eq "trace events" 1100 "$(kv_get "$mb/mech.stats" MECH_TRACE_EVENTS)"
t_eq "lost = trace lost" 5 "$(kv_get "$mb/mech.stats" MECH_LOST)"
t_eq "drop rate" 0.002494 "$(kv_get "$mb/mech.stats" MECH_DROP_RATE)"
printf '%s\n' '              LOST events:        2' >> "$mb/perf_report_stats.txt"
sed -i '1a\               LOST events:        2' "$mb/perf_report_stats.txt"
t_die "loss records without perf.data" mech_stats "$mb"
: > "$mb/perf.data"
perf() {  # stub: --stats rewrites the saved file; -D prints two loss records
  case $1 in
    report) if [[ $2 == --stats ]]; then printf '%s\n' 'Aggregated stats:' '              SAMPLE events:      900' '                LOST events:        2'
            else printf '%s\n' '0x10 [0x30]: event: 2' '0x10 [0x30]: PERF_RECORD_LOST: id:5: lost:4000' 'x' '0x40 [0x30]: PERF_RECORD_LOST: id:5: lost:95' '                LOST events:        2'; fi ;;
  esac
}
zstd() { :; }
mech_stats "$mb"
t_eq "record lost samples summed" 4095 "$(kv_get "$mb/mech.stats" MECH_REC_LOST)"
t_eq "lost total" 4100 "$(kv_get "$mb/mech.stats" MECH_LOST)"
t_eq "loss records" 2 "$(kv_get "$mb/mech.stats" MECH_REC_LOSS_RECORDS)"
perf() { case $1 in report) if [[ $2 == --stats ]]; then printf '%s\n' '              SAMPLE events:      900' '                LOST events:        3'
         else printf '%s\n' 'PERF_RECORD_LOST: id:5: lost:4000'; fi ;; esac; }
t_die "record count mismatch dies" mech_stats "$mb"
unset -f perf zstd

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
  kv_put "$b/run_meta.env" RUN_SCHEMA "$SCHEMA_VERSION"
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
t_eq "irq split present" 1 "$(grep '_A1' "$csv" | grep -c v_IRQ_DEV_DELTA)"
t_eq "power source present" 1 "$(grep '_A1' "$csv" | grep -c v_POWER_SOURCE)"
ab2="$RD/raw/$(run_id nginx perf narrow 1 1 A2)"
for k in $LATE_KEYS; do sed -i "/^$k=/d" "$ab2/samples/summary.env" "$ab2/power.env"; done
sed -i '/^RUN_SCHEMA=/d' "$ab2/run_meta.env"
collect nginx perf "$RD" >/dev/null 2>&1
t_eq "pre-2.0 bundle: 8 irq + power + 4 mech NA" 13 "$(grep '_A2' "$csv" | grep -o '"NA"' | wc -l | tr -d ' ')"
sed -i '/^IRQ_PMI_DELTA=/d' "$RD/raw/$(run_id nginx perf narrow 1 1 A1)/samples/summary.env"
t_die "partial split dies" collect nginx perf "$RD"
kv_put "$RD/raw/$(run_id nginx perf narrow 1 1 A1)/samples/summary.env" IRQ_PMI_DELTA v
sed -i '/^P99_MS=/d' "$RD/raw/$(run_id nginx perf narrow 1 1 B1)/wl.env"
t_die "collect dies on missing key" collect nginx perf "$RD"

# --- collect in capacity mode: drift brackets kept, verdict column, rates in schema ---
(
  RD="$T/cap"; mkdir -p "$RD/raw"; CAPACITY=1 CAPACITY_RATES=40000,44000
  for r in A1 B1 A2; do mk_bundle "$r"; done                       # ids "L_cap_…": RD is read by mk_bundle
  vf="$RD/raw/$(run_id nginx perf narrow 1 1 X)"; kv_put "${vf%_try1_X}_try1.verdict" VERDICT drift
  collect nginx perf "$RD" >/dev/null 2>&1
  c="$RD/nginx_perf.csv"
  echo "rows $(($(wc -l < "$c") - 1))"
  echo "last $(head -1 "$c" | awk -F, '{print $NF}')"
  echo "verdict $(grep -c '"drift"$' "$c")"
  echo "ids $(grep -c '^"L_cap_' "$c")"
  echo "rates $(grep -c '"capacity_rates": "40000,44000",' "$RD/schema.json")"
  CAPACITY=0; rm -f "$c" "$RD/schema.json"; collect nginx perf "$RD" >/dev/null 2>&1
  echo "matrix skips drift $(($(wc -l < "$c") - 1))"
) > "$T/cap.out" 2>&1
t_eq "capacity: drift rows kept" "rows 3" "$(sed -n 1p "$T/cap.out")"
t_eq "capacity: verdict column last" 'last "bracket_verdict"' "$(sed -n 2p "$T/cap.out")"
t_eq "capacity: verdict value" "verdict 3" "$(sed -n 3p "$T/cap.out")"
t_eq "capacity: run ids" "ids 3" "$(sed -n 4p "$T/cap.out")"
t_eq "capacity: rates in schema" "rates 1" "$(sed -n 5p "$T/cap.out")"
t_eq "matrix mode still skips drift" "matrix skips drift 0" "$(sed -n 6p "$T/cap.out")"

# --- schema.json: finished matrices must re-freeze byte-identical; collector adds its constants ---
( source "$LAPTOP_ROOT/common/config.env"   # earlier tests change WORKLOAD_CPUS
  LADDER="1:5000 2:10000 3:20000 4:40000"
  for m in perf ebpf; do
    mkdir -p "$T/sch_$m"; _schema_freeze "$T/sch_$m" "$m" >/dev/null 2>&1
    cmp -s "$T/sch_$m/schema.json" "$LAPTOP_ROOT/nginx-wrk2/$m/results/schema.json" && echo ok || echo "bad $m: $(diff "$T/sch_$m/schema.json" "$LAPTOP_ROOT/nginx-wrk2/$m/results/schema.json" | grep "^[<>]" | cut -c1-120 | tr "
" " ")"
  done
  source "$LAPTOP_ROOT/nginx-wrk2/collector/scripts/collector.env"
  mkdir -p "$T/sch_c"; _schema_freeze "$T/sch_c" collector >/dev/null 2>&1
  grep -q '"otelcol_version": "0.161.0"' "$T/sch_c/schema.json" && grep -q '"collector_scrape_interval_wide_s": 1,' "$T/sch_c/schema.json" && echo ok || echo "bad collector"
) > "$T/sch.out"
while read -r r; do [[ $r == ok ]] && ok || bad "schema: $r"; done < "$T/sch.out"

# --- provenance.sh ---
source "$LAPTOP_ROOT/common/provenance.sh"
( EBPF_PYTHON=/nonexistent OTELCOL_BIN=/nonexistent WRK2_BIN=/nonexistent; provenance_write "$T/prov" perf ) >/dev/null 2>&1
pf=$(ls "$T"/prov/provenance/*_perf.env 2>/dev/null | head -1)
t_eq "provenance file" yes "$([[ -n $pf ]] && echo yes || echo no)"
t_eq "provenance commit" 40 "$(kv_get "$pf" HARNESS_COMMIT | tr -d '\n' | wc -c | tr -d ' ')"
t_eq "provenance missing tool NA" NA "$(kv_get "$pf" OTELCOL_VERSION)"

# --- power.sh (fake power_supply tree; host/probe stubbed) ---
source "$LAPTOP_ROOT/common/power.sh"
POWER_SUPPLY_DIR="$T/ps"; POWER_STATE_FILE="$T/power_last"
mkdir -p "$POWER_SUPPLY_DIR/ACAD" "$POWER_SUPPLY_DIR/BAT1"
echo Mains > "$POWER_SUPPLY_DIR/ACAD/type"; echo 1 > "$POWER_SUPPLY_DIR/ACAD/online"
echo Battery > "$POWER_SUPPLY_DIR/BAT1/type"; echo 80 > "$POWER_SUPPLY_DIR/BAT1/capacity"
t_eq "ac online" 1 "$(ac_online)"
t_eq "battery pct" 80 "$(battery_pct)"
REASSERTS=0
host_reassert() { REASSERTS=$((REASSERTS+1)); echo r >> "$T/reasserts"; }
power_probe() { printf '%s 2890000 2910000' "${PROBE_VERDICT:-ok}"; }
pb2="$T/pw1"; mkdir -p "$pb2"
power_gate "$pb2" 2>/dev/null
t_eq "gate on AC" ac "$(kv_get "$pb2/power.env" POWER_SOURCE_START)"
t_eq "no probe on AC" no "$(kv_has "$pb2/power.env" PROBE_BATTERY && echo yes || echo no)"
echo 0 > "$POWER_SUPPLY_DIR/ACAD/online"
t_eq "ac offline" 0 "$(ac_online)"
power_end "$pb2" 2>/dev/null
t_eq "source changed mid-run -> mixed" mixed "$(kv_get "$pb2/power.env" POWER_SOURCE)"
pb3="$T/pw2"; mkdir -p "$pb3"; : > "$T/reasserts"
power_gate "$pb3" 2>/dev/null
t_eq "battery ok -> runs on battery" battery "$(kv_get "$pb3/power.env" POWER_SOURCE_START)"
t_eq "battery probe recorded" ok "$(kv_get "$pb3/power.env" PROBE_BATTERY)"
t_eq "reassert on battery" 1 "$(wc -l < "$T/reasserts" | tr -d ' ')"
power_end "$pb3" 2>/dev/null
t_eq "battery whole run" battery "$(kv_get "$pb3/power.env" POWER_SOURCE)"
pb4="$T/pw3"; mkdir -p "$pb4"
POWER_WAIT_S=0 PROBE_VERDICT=out_of_band t_die "probe fails, no AC -> dies" power_gate "$pb4"
echo 20 > "$POWER_SUPPLY_DIR/BAT1/capacity"
POWER_WAIT_S=0 t_die "low battery, no AC -> dies" power_gate "$pb4"
sleep() { echo 1 > "$POWER_SUPPLY_DIR/ACAD/online"; }   # AC returns during the wait
pb5="$T/pw4"; mkdir -p "$pb5"; : > "$T/reasserts"
power_gate "$pb5" 2>/dev/null
t_eq "low battery waits, AC back -> ac" ac "$(kv_get "$pb5/power.env" POWER_SOURCE_START)"
t_eq "probe re-run on AC" ok "$(kv_get "$pb5/power.env" PROBE_AC)"
unset -f sleep
pb6="$T/pw5"; mkdir -p "$pb6"; : > "$T/reasserts"; echo battery > "$POWER_STATE_FILE"
power_gate "$pb6" 2>/dev/null
t_eq "AC back between runs -> reassert" 1 "$(wc -l < "$T/reasserts" | tr -d ' ')"
rm -rf "$POWER_SUPPLY_DIR/ACAD"
t_eq "no Mains supply" 2 "$(ac_online)"

# --- eBPF mech_stats ---
source "$LAPTOP_ROOT/nginx-wrk2/ebpf/scripts/mech.sh"
eb="$T/ebpf"; mkdir -p "$eb"; : > "$eb/mech.meta"
mk_ebpf_stats() {  # mk_ebpf_stats RECEIVED LOST SUBMITTED FAILED EXIT
  : > "$eb/ebpf_stats.env"
  for kv in EBPF_LIBRARY=bcc EBPF_SCOPE=wide EBPF_FILTER_ENTRIES=4 EBPF_PERF_BUFFER_PAGES=512 \
            "EBPF_EVENTS_RECEIVED=$1" "EBPF_EVENTS_LOST=$2" "EBPF_KERNEL_SUBMITTED=$3" \
            "EBPF_KERNEL_SUBMIT_FAILED=$4" EBPF_KERNEL_FILTERED=500 EBPF_KERNEL_SECONDARY=1000 \
            EBPF_STOP=signal "EBPF_EXIT=$5"; do kv_put "$eb/ebpf_stats.env" "${kv%%=*}" "${kv#*=}"; done
}
mk_ebpf_stats 900 100 1000 100 ok
mech_stats "$eb"
t_eq "ebpf events" 900 "$(kv_get "$eb/mech.stats" MECH_EVENTS)"
t_eq "ebpf lost" 100 "$(kv_get "$eb/mech.stats" MECH_LOST)"
t_eq "ebpf drop rate" 0.100000 "$(kv_get "$eb/mech.stats" MECH_DROP_RATE)"
t_eq "ebpf unaccounted 0" 0 "$(kv_get "$eb/mech.stats" EBPF_UNACCOUNTED)"
t_eq "ebpf filtered ratio" 0.5000 "$(kv_get "$eb/mech.stats" EBPF_FILTERED_PER_SUBMIT)"
t_eq "ebpf notes" "ebpf_lost=100;" "$(kv_get "$eb/mech.stats" MECH_NOTES)"
t_ok "ebpf sanity" mech_sanity "$eb"
mk_ebpf_stats 990 0 1000 0 ok; mech_stats "$eb"
t_eq "ebpf unaccounted noted" "unaccounted=10;" "$(kv_get "$eb/mech.stats" MECH_NOTES)"
mk_ebpf_stats 0 0 0 0 ok; mech_stats "$eb"
t_die "ebpf saw nothing dies" mech_sanity "$eb"
mk_ebpf_stats 900 0 900 0 stopped_max_window
t_die "ebpf unclean stop dies" mech_stats "$eb"
rm -f "$eb/ebpf_stats.env"
t_die "ebpf no stats dies" mech_stats "$eb"

# --- bcc_tracer.py pure helpers (no bcc needed) ---
PY=""
for c in python3 python; do "$c" -c "import sys" >/dev/null 2>&1 && { PY=$c; break; }; done
if [[ -n $PY ]]; then
  t_eq "tracer helpers" ok "$("$PY" -I -c '
import sys; sys.path.insert(0, sys.argv[1]); import bcc_tracer as t
assert t.parse_id_list("1, 2,3", "x") == [1, 2, 3]
for bad in ("", "1,a"):
    try: t.parse_id_list(bad, "x"); raise AssertionError(bad)
    except SystemExit: pass
t.check_buffer_pages(512)
try: t.check_buffer_pages(500); raise AssertionError("500")
except SystemExit: pass
try: t.check_cpus([0, 1024]); raise AssertionError("1024")
except SystemExit: pass
assert t.kv_lines([("A", 1), ("B", "x'"'"'y")]) == "A='"'"'1'"'"'\nB='"'"'xy'"'"'\n"
a = t.parse_args(["--scope", "wide", "--src", "p.c", "--stats", "s", "--ready", "r", "--buffer-pages", "512", "--max-window", "9"])
assert a.max_window == 9 and a.scope == "wide" and a.src == "p.c"
import contextlib, io  # argparse prints its usage to stderr; the harness captures 2>&1
try:
    with contextlib.redirect_stderr(io.StringIO()): t.parse_args(["--scope", "wide", "--stats", "s", "--ready", "r", "--buffer-pages", "512", "--max-window", "9"])
    raise AssertionError("no --src")
except SystemExit: pass
assert t.parse_dev_list("259:0") == [259 << 20]
assert t.parse_dev_list("259:1, 8:0") == [(259 << 20) | 1, 8 << 20]
for bad in ("", "259", "a:b", "4096:0", "8:1048576"):
    try: t.parse_dev_list(bad); raise AssertionError(bad)
    except SystemExit: pass
for argv in (["--pids", "1", "--devs", "8:0"], []):
    try: t.check_narrow_filter(t.parse_args(["--scope", "narrow", "--src", "p.c", "--stats", "s", "--ready", "r", "--buffer-pages", "512", "--max-window", "9"] + argv)); raise AssertionError(argv)
    except SystemExit: pass
t.check_narrow_filter(t.parse_args(["--scope", "narrow", "--src", "p.c", "--stats", "s", "--ready", "r", "--buffer-pages", "512", "--max-window", "9", "--devs", "8:0"]))
print("ok")' "$LAPTOP_ROOT/common/mech" 2>&1)"
fi

# --- progress.sh (pure parts + a full cell with no console) ---
(
  STATE_DIR="$T/pstate" LAPTOP_ROOT="$T/proot"; mkdir -p "$LAPTOP_ROOT"
  WARMUP_REPS=1 MEASURED_REPS=6 QUIESCED=0 STATUS_HOLD_S=0
  source "$HERE/../progress.sh"
  t_eq "fmt_dur min" "4m05s" "$(fmt_dur 245)"
  t_eq "fmt_dur hour" "1h02m" "$(fmt_dur 3720)"
  t_eq "per try" 9 "$P_PER_TRY"
  t_eq "left before start" 72 "$(progress_runs_left 8 0 9 0)"
  t_eq "left mid cell 1" 70 "$(progress_runs_left 8 1 9 2)"
  t_eq "left last cell done" 0 "$(progress_runs_left 8 8 9 9)"
  progress_init 2
  t_eq "no console without quiesce" "" "$P_TTY"
  progress_cell L_nginx_x_narrow_E1
  progress_run B1 2 1; progress_run_done
  t_eq "runs timed" 1 "$P_RUNS"
  grep -q 'run B1 (3/9)' "$PROGRESS_FILE" && ok || bad "status line shows run"
  progress_cell_end L_nginx_x_narrow_E1 1 drift "p99 1%/5%  cpu 6%/5%"
  t_eq "drift restarts try" 0 "$P_IDX"
  progress_cell_end L_nginx_x_narrow_E1 2 ok "p99 1%/5%  cpu 1%/5%"
  t_eq "history" 2 "${#P_HIST[@]}"
  progress_finish 0
  grep -q 'FINISHED 1/2 cells ok' "$PROGRESS_FILE" && ok || bad "finish line"
  P_ON=0; CRASH_ERRFILE="$T/err"; echo "12:00:00 die stage=x: boom (in f)" > "$CRASH_ERRFILE"
  progress_finish 1
  grep -q 'ABORTED: stage=x: boom' "$PROGRESS_FILE" && ok || bad "abort reason: $(cat "$PROGRESS_FILE")"
  echo "$NPASS $NFAIL" > "$T/pcount"
)
read -r NPASS NFAIL < "$T/pcount"

# --- nginx x collector plugin (its own file; runs standalone too) ---
source "$LAPTOP_ROOT/nginx-wrk2/collector/tests/test_mech.sh"

printf '%s passed, %s failed\n' "$NPASS" "$NFAIL"
(( NFAIL == 0 ))
