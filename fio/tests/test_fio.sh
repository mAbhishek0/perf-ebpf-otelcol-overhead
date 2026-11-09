#!/usr/bin/env bash
# test_fio.sh — logic tests for the fio workload; no root, no fio, no
# hardware:  bash fio/tests/test_fio.sh   (common/tests/run_tests.sh runs it
# too). Tools that need hardware (findmnt, fstrim, sleep) are PATH stubs.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAPTOP_ROOT="$(cd "$HERE/../.." && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
LOG_TAG=test
source "$LAPTOP_ROOT/common/collect.sh"
source "$LAPTOP_ROOT/common/provenance.sh"   # _prov_cmd
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
NPASS=0 NFAIL=0
ok()   { NPASS=$((NPASS+1)); }
bad()  { NFAIL=$((NFAIL+1)); printf 'FAIL: %s\n' "$*"; }
t_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1: expected '$2' got '$3'"; fi; }
t_die() { local d=$1; shift; if ( "$@" ) >/dev/null 2>&1; then bad "$d: expected failure"; else ok; fi; }
t_has() { if grep -qxF -- "$3" "$2"; then ok; else bad "$1: no line '$3' in $2"; fi; }

PY=""
for c in python3 python; do "$c" -c "import sys" >/dev/null 2>&1 && { PY=$c; break; }; done
FIO_PYTHON=${PY:-python3}
source "$LAPTOP_ROOT/fio/workload.sh"
FIO_NUMJOBS=4 FIO_IODEPTH=32 RAMP_S=30 STEADY_S=120

# --- per-job rate ---
t_eq "per-job rate" 25000 "$(_fio_per_job_rate 100000)"
t_die "rate not divisible" _fio_per_job_rate 100002
t_die "rate zero" _fio_per_job_rate 0

# --- job file ---
b="$T/b"; mkdir -p "$b"
_fio_jobfile 100000 "$b" > "$b/fio.job"
for line in "rw=randread" "bs=4k" "direct=1" "ioengine=libaio" "thread" "numjobs=4" "iodepth=32" \
            "rate_iops=25000" "randrepeat=1" "randseed=20261014" "time_based" "group_reporting" \
            "cpus_allowed=0,2,4,6" "cpus_allowed_policy=split" "lat_percentiles=1" "clat_percentiles=0" \
            "percentile_list=50:99:99.9" "[ramp]" "runtime=30" "[measure]" "stonewall" "runtime=120" \
            "exec_prerun=/bin/sh $b/gate.sh" "filename=$FIO_FILE" "size=$FIO_FILE_BYTES"; do
  t_has "job file" "$b/fio.job" "$line"
done

# --- gate: waits for go, then exits 0; times out with exit 1 ---
_fio_gate "$b" > "$b/gate.sh"
sh -n "$b/gate.sh" && ok || bad "gate.sh does not parse"
( sleep 0.3; : > "$b/go" ) &
sh "$b/gate.sh"; t_eq "gate released by go" 0 "$?"
t_eq "gate left a ready marker" 1 "$(_fio_ready_count "$b")"
[[ "$(cat "$b"/ready.*)" =~ ^[0-9]{16,}$ ]] && ok || bad "ready marker does not hold a ns timestamp"
rm -f "$b/go" "$b"/ready.*
FIO_GATE_TIMEOUT_S=1 _fio_gate "$b" > "$b/gate_short.sh"
sh "$b/gate_short.sh"; t_eq "gate times out" 1 "$?"

# --- gate wait: oldest ready marker to go; dies on a blank or bad marker ---
gw="$T/gw"; mkdir -p "$gw"
echo 1700000000000000000 > "$gw/ready.11"; echo 1700000002500000000 > "$gw/ready.12"
t_eq "gate wait from the oldest marker" 4.000 "$(_fio_gate_wait_s "$gw" 1700000004000000000)"
t_die "gate wait: go before ready" _fio_gate_wait_s "$gw" 1699999999000000000
t_die "gate wait: bad go time" _fio_gate_wait_s "$gw" ""
: > "$gw/ready.13"; rm -f "$gw/ready.11" "$gw/ready.12"
t_die "gate wait: blank marker" _fio_gate_wait_s "$gw" 1700000004000000000
rm -f "$gw"/ready.*
t_die "gate wait: no marker" _fio_gate_wait_s "$gw" 1700000004000000000
# under the harness's set -euo pipefail the clear message must still print
v=$( (set -euo pipefail; _fio_gate_wait_s "$gw" 1700000004000000000) 2>&1 )
[[ $v == *"no usable ready.* timestamp"* ]] && ok || bad "gate wait: no marker under set -e gave '$v'"

# --- ladder / pilot / capacity rates must divide by FIO_NUMJOBS ---
( FIO_NUMJOBS=4 LADDER="1:10000 2:25000" RATES=50000,100000 CAPACITY_RATES=44000 _fio_check_rates ) && ok || bad "even rates rejected"
_rates_die() { FIO_NUMJOBS=$1 LADDER="$2" RATES="$3" CAPACITY_RATES="$4" _fio_check_rates; }
t_die "ladder rate not divisible (call-time)" _rates_die 4 "1:10000 2:25002" "" ""
t_die "pilot rate not divisible" _rates_die 4 "" "10000,15001" ""
t_die "capacity rate not divisible" _rates_die 4 "" "" "44002"
t_die "ladder fits 4 jobs but not 3" _rates_die 3 "1:10000" "" ""
msg=$( ( _rates_die 4 "1:10000 2:25002" "" "" ) 2>&1 ); [[ $msg == *25002* ]] && ok || bad "message does not name the bad rate: $msg"

# --- wl_parse on the fixture, with disk counters ---
cp "$LAPTOP_ROOT/fio/tests/fixtures/fio_synthetic.json" "$b/fio.json"
echo "1000 0 8000 50 200 0 1600 70 0 900 120 0 0 0 0 0 0" > "$b/diskstat_before.txt"
echo "6001000 0 48008000 300000 230 0 1840 80 0 120900 300120 0 0 0 0 0 0" > "$b/diskstat_after.txt"
echo 0.412 > "$b/gate_wait_s"
if [[ -n $PY ]]; then
  ( wl_parse "$b" ) && ok || bad "wl_parse failed"
  t_eq "parse throughput" 49998.50 "$(kv_get "$b/wl.env" THROUGHPUT)"
  t_eq "parse p99" 0.160768 "$(kv_get "$b/wl.env" P99_MS)"
  t_eq "disk reads delta" 6000000 "$(kv_get "$b/wl.env" FIO_DISK_READS_DELTA)"
  t_eq "disk writes delta" 30 "$(kv_get "$b/wl.env" FIO_DISK_WRITES_DELTA)"
  t_eq "gate wait in wl.env" 0.412 "$(kv_get "$b/wl.env" GATE_WAIT_S)"
  cp "$b/diskstat_after.txt" "$b/ds_ok"
  echo "garbage" > "$b/diskstat_after.txt"
  t_die "wl_parse bad disk reads" wl_parse "$b"
  echo "6001000 0 48008000 300000 xx 0 1840 80 0 120900 300120 0 0 0 0 0 0" > "$b/diskstat_after.txt"
  t_die "wl_parse bad disk writes" wl_parse "$b"
  echo "6001000 0 48008000 300000 100 0 1840 80 0 120900 300120 0 0 0 0 0 0" > "$b/diskstat_after.txt"
  t_die "wl_parse negative disk writes" wl_parse "$b"
  cp "$b/ds_ok" "$b/diskstat_after.txt"
  rm -f "$b/gate_wait_s"
  t_die "wl_parse without a gate wait" wl_parse "$b"
  echo 0.412 > "$b/gate_wait_s"
  t_die "wl_parse runtime guard" eval 'STEADY_S=60 wl_parse "$b"'
fi

# --- wl_cell_prep: fstrim + idle, stubbed ---
mkdir -p "$T/bin"
printf '#!/bin/sh\necho /\n' > "$T/bin/findmnt"
printf '#!/bin/sh\necho "/: 1 GiB (1073741824 bytes) trimmed"\n' > "$T/bin/fstrim"
chmod +x "$T/bin/findmnt" "$T/bin/fstrim"
( PATH="$T/bin:$PATH" FIO_CELL_IDLE_S=0 wl_cell_prep "$T/c_try1.prep" ) && ok || bad "wl_cell_prep failed"
t_eq "prep trim line" "/: 1 GiB (1073741824 bytes) trimmed" "$(kv_get "$T/c_try1.prep" FSTRIM)"
t_eq "prep idle" 0 "$(kv_get "$T/c_try1.prep" IDLE_S)"
( FIO_CELL_TRIM=0 wl_cell_prep "$T/c_try2.prep" ) && ok || bad "prep off failed"
[[ ! -e $T/c_try2.prep ]] && ok || bad "prep off still wrote a file"
printf '#!/bin/sh\necho "fstrim: busy" >&2; exit 1\n' > "$T/bin/fstrim"
_prep_fail() { PATH="$T/bin:$PATH" FIO_CELL_IDLE_S=0 wl_cell_prep "$T/c_try3.prep"; }
t_die "prep fstrim failure dies" _prep_fail

# --- provenance: the new keys are always written, never blank ---
# The paths (/boot/config-<kernel>, /proc/cmdline, /sys/module/nvme_core) are
# fixed, as the existing provenance reads are, so this checks the keys and
# that a missing source gives "unknown" or NA rather than a blank; it cannot
# pin the values.
pv="$T/prov.env"; : > "$pv"
( FIO_FILE="$T/nofile" FIO_DEV=nvme0n1 wl_provenance "$pv" ) && ok || bad "wl_provenance failed"
for k in KERNEL_CONFIG_IRQ_TIME_ACCOUNTING KERNEL_CMDLINE NVME_DEFAULT_PS_MAX_LATENCY_US; do
  kv_has "$pv" "$k" && [[ -n "$(kv_get "$pv" "$k")" ]] && ok || bad "provenance lacks or blanks $k"
done
v=$(_fio_irq_config); [[ $v == unknown || $v == *CONFIG_IRQ_TIME_ACCOUNTING* ]] && ok || bad "irq config line: $v"
v=$(_fio_nvme_ps_latency); [[ $v == unknown || $v =~ ^[0-9]+$ ]] && ok || bad "nvme ps latency: $v"

# --- schema: fio constants are frozen ---
mkdir -p "$T/s"
LADDER="1:10000" _schema_freeze "$T/s" perf
grep -q '"fio_numjobs": 4' "$T/s/schema.json" && ok || bad "schema lacks fio_numjobs"
grep -q '"fio_rw": "randread"' "$T/s/schema.json" && ok || bad "schema lacks fio_rw"

# --- workload CSV columns (wl_csv_columns): after the shared columns, values from wl.env ---
FIO_COLS='"fio_runtime_ms","fio_total_ios","fio_ramp_iops","fio_disk_reads_delta","fio_disk_writes_delta","gate_wait_s"'
_fio_bundle() {  # RD ROLE -> one fio bundle with every shared key, wl.env from the fixture
  local rd=$1 role=$2 id b col name src key val
  id=$(run_id fio perf narrow 1 1 "$role"); b="$rd/raw/$id"; mkdir -p "$b/samples"
  for col in "${CSV_COLUMNS[@]}"; do
    IFS=: read -r name src key <<<"$col"
    [[ $src == mech ]] && continue
    case $key in RUN_ID) val=$id ;; ROLE) val=$role ;; TRACED) val=0 ;; *) val="v_$key" ;; esac
    kv_put "$b/$(_col_file "$src")" "$key" "$val"
  done
  kv_put "$b/run_meta.env" RUN_SCHEMA "$SCHEMA_VERSION"
  cat "$HERE/fixtures/wl_fio.env" >> "$b/wl.env"
  touch "$b/DONE"
  echo "$b"
}
_fio_collect() {  # RD -> collect fio perf into RD, quietly
  local vf
  vf="$1/raw/$(run_id fio perf narrow 1 1 X)"; vf="${vf%_try1_X}_try1.verdict"
  [[ -f $vf ]] || kv_put "$vf" VERDICT ok
  LADDER="1:10000" collect fio perf "$1" >/dev/null 2>&1
}
RD="$T/fcsv"; mkdir -p "$RD/raw"; _fio_bundle "$RD" A1 >/dev/null
_fio_collect "$RD" && ok || bad "fio collect failed"
csv="$RD/fio_perf.csv"
shared=""; for c in "${CSV_COLUMNS[@]}"; do shared+="${shared:+,}\"${c%%:*}\""; done
t_eq "fio header = shared columns then the six fio columns" "$shared,$FIO_COLS" "$(head -1 "$csv")"
t_eq "fio row values" '"120000","1200000","9999.50","1200123","42","0.731"' "$(sed -n 2p "$csv" | cut -d, -f$(( ${#CSV_COLUMNS[@]} + 1 ))-)"
grep -q "\"gate_wait_s\"\]" "$RD/schema.json" && ok || bad "schema columns lack the fio columns"
t_has "schema column units" "$RD/schema.json" '  "workload_column_units": {"fio_runtime_ms": "ms", "fio_total_ios": "I/Os", "fio_ramp_iops": "IOPS", "fio_disk_reads_delta": "completed requests", "fio_disk_writes_delta": "completed requests", "gate_wait_s": "s"},'
# restat path: a second collect (what restat.sh runs, after sourcing workload.sh) reproduces the row
cp "$csv" "$T/fcsv_first.csv"
_fio_collect "$RD" && cmp -s "$csv" "$T/fcsv_first.csv" && ok || bad "re-collect did not reproduce the fio CSV"
# fail loudly: missing, blank or malformed values die; no blank cell is written
_fio_bad() {  # SED_EXPR -> collect on a fresh dir whose wl.env was edited
  local rd="$T/fbad$RANDOM" b
  mkdir -p "$rd/raw"; b=$(_fio_bundle "$rd" A1)
  sed -i "$1" "$b/wl.env"
  _fio_collect "$rd"
}
t_die "fio column missing dies" _fio_bad '/^GATE_WAIT_S=/d'
t_die "fio column blank dies" _fio_bad "s/^FIO_TOTAL_IOS=.*/FIO_TOTAL_IOS=''/"
t_die "fio column malformed dies" _fio_bad "s/^FIO_RAMP_IOPS=.*/FIO_RAMP_IOPS='fast'/"
t_die "fio column negative dies" _fio_bad "s/^FIO_DISK_WRITES_DELTA=.*/FIO_DISK_WRITES_DELTA='-3'/"
t_die "fio column NA dies" _fio_bad "s/^FIO_RUNTIME_MS=.*/FIO_RUNTIME_MS='NA'/"
# a wl_csv_columns hook that exits non-zero makes collect die (not a silent short list)
_hook_fails() { wl_csv_columns() { echo 'x_ms:X_MS:ms'; return 1; }; _csv_cols; }
t_die "wl_csv_columns hook exits non-zero dies" _hook_fails
unset -f _hook_fails

# --- eBPF probe file: the shared parts are byte-identical to nginx's ---
np="$LAPTOP_ROOT/nginx-wrk2/ebpf/scripts/nginx_probes.c"
fp="$LAPTOP_ROOT/fio/ebpf/scripts/fio_probes.c"
wide() { sed -n '/^#ifdef SCOPE_WIDE/,/^#endif \/\* SCOPE_WIDE \*\//p' "$1"; }
core() { sed -n '/^struct event_t {/,/^#ifdef SCOPE_NARROW/p' "$1"; }
[[ -s $fp && "$(wide "$np")" == "$(wide "$fp")" ]] && ok || bad "fio_probes.c wide section differs from nginx_probes.c"
[[ -s $fp && "$(core "$np")" == "$(core "$fp")" ]] && ok || bad "fio_probes.c event/emit core differs from nginx_probes.c"
grep -q 'TRACEPOINT_PROBE(block, block_rq_issue)' "$fp" && ok || bad "no block_rq_issue probe"
grep -q 'TRACEPOINT_PROBE(block, block_rq_complete)' "$fp" && ok || bad "no block_rq_complete probe"
grep -q 'BPF_HASH(target_devs' "$fp" && ok || bad "no target_devs map (bcc_tracer --devs fills it)"

# --- collector templates: receivers and scrapers, and the shared tail ---
(
  source "$LAPTOP_ROOT/fio/collector/scripts/mech.sh"
  cd_="$LAPTOP_ROOT/fio/collector/scripts"; nd="$LAPTOP_ROOT/nginx-wrk2/collector/scripts"
  for sc in narrow wide; do
    _otel_render "$cd_/otelcol_scraper_$sc.yaml.template" 1 "" 18888 512 512 > "$T/$sc.yaml"
    _otel_unsubstituted "$T/$sc.yaml" && bad "$sc: placeholder left" || ok
    t_eq "$sc counts" "$(collector_want $sc)" "$(_otel_receiver_count "$T/$sc.yaml") $(_otel_hostmetrics_scrapers "$T/$sc.yaml")"
    tail_() { sed -n '/^processors:/,$p' "$1"; }
    [[ "$(tail_ "$cd_/otelcol_scraper_$sc.yaml.template" | grep -v '^ *receivers: \[')" == \
       "$(tail_ "$nd/otelcol_scraper_$sc.yaml.template" | grep -v '^ *receivers: \[')" ]] && ok || bad "$sc: template tail differs from nginx's"
  done
  echo "$NPASS $NFAIL" > "$T/ccount"
)
read -r NPASS NFAIL < "$T/ccount" 2>/dev/null || bad "collector templates block aborted (no count file)"

# --- perf and eBPF wrappers load and point at the right things ---
( source "$LAPTOP_ROOT/fio/perf/scripts/mech.sh"; [[ $PERF_TARGET_DESC == *fio* ]] && declare -F mech_attach >/dev/null ) \
  && ok || bad "fio perf wrapper"
( source "$LAPTOP_ROOT/fio/ebpf/scripts/mech.sh"; [[ $EBPF_PROBES_SRC == */fio_probes.c ]] && declare -F ebpf_narrow_filter >/dev/null ) \
  && ok || bad "fio eBPF wrapper"

# --- fio collector: mech_stats with hostmetrics only gives nginx points 0, not blank ---
(
  source "$LAPTOP_ROOT/fio/collector/scripts/mech.sh"
  cb="$T/fotel"; mkdir -p "$cb"
  : > "$cb/mech.meta"
  for kv in OTEL_MODE=scraper OTEL_SCOPE=narrow OTEL_SCRAPE_INTERVAL_S=15 OTEL_RECEIVER_COUNT=1 \
            OTEL_HOSTMETRICS_SCRAPERS=1 OTEL_SENDING_QUEUE_SIZE=512 OTEL_BATCH_SIZE=512 \
            OTEL_VERSION=0.161.0 OTEL_PID=4242 OTEL_ATTACH_S=1.2 OTEL_T_BASELINE=1000.0; do
    kv_put "$cb/mech.meta" "${kv%%=*}" "${kv#*=}"
  done
  : > "$cb/otel_stop.env"; kv_put "$cb/otel_stop.env" OTEL_T_FINAL 1121.5; kv_put "$cb/otel_stop.env" OTEL_EXIT ok
  cat > "$cb/otel_baseline.prom" <<'PROM'
otelcol_receiver_accepted_metric_points{receiver="hostmetrics",transport=""} 100
otelcol_exporter_sent_metric_points{exporter="debug"} 100
otelcol_scraper_scraped_metric_points{receiver="hostmetrics",scraper="disk"} 50
otelcol_process_cpu_seconds 2.0
PROM
  cat > "$cb/otel_final.prom" <<'PROM'
otelcol_receiver_accepted_metric_points{receiver="hostmetrics",transport=""} 1000
otelcol_exporter_sent_metric_points{exporter="debug"} 1000
otelcol_scraper_scraped_metric_points{receiver="hostmetrics",scraper="disk"} 450
otelcol_exporter_queue_size{exporter="debug"} 0
otelcol_exporter_queue_capacity{exporter="debug"} 512
otelcol_process_memory_rss 2.13e+08
otelcol_process_cpu_seconds 5.0
PROM
  printf '2026-11-07T10:00:00Z\tinfo\tservice@v0.161.0/service.go:1\tEverything is ready.\n' > "$cb/otelcol.log"
  mech_stats "$cb"
  t_eq "fio collector: nginx points" 0 "$(kv_get "$cb/mech.stats" OTEL_NGINX_ACCEPTED_METRIC_POINTS)"
  (( $(kv_get "$cb/mech.stats" OTEL_HOSTMETRICS_ACCEPTED_METRIC_POINTS) > 0 )) && ok || bad "fio collector: hostmetrics points"
  ( mech_sanity "$cb" ) && ok || bad "fio collector sanity"
  echo "$NPASS $NFAIL" > "$T/ccount2"
)
read -r NPASS NFAIL < "$T/ccount2" 2>/dev/null || bad "collector mech_stats block aborted (no count file)"

printf 'fio tests: %s passed, %s failed\n' "$NPASS" "$NFAIL"
(( NFAIL == 0 ))
