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
rm -f "$b/go" "$b"/ready.*
FIO_GATE_TIMEOUT_S=1 _fio_gate "$b" > "$b/gate_short.sh"
sh "$b/gate_short.sh"; t_eq "gate times out" 1 "$?"

# --- wl_parse on the fixture, with disk counters ---
cp "$LAPTOP_ROOT/fio/tests/fixtures/fio_synthetic.json" "$b/fio.json"
echo "1000 0 8000 50 200 0 1600 70 0 900 120 0 0 0 0 0 0" > "$b/diskstat_before.txt"
echo "6001000 0 48008000 300000 230 0 1840 80 0 120900 300120 0 0 0 0 0 0" > "$b/diskstat_after.txt"
if [[ -n $PY ]]; then
  ( wl_parse "$b" ) && ok || bad "wl_parse failed"
  t_eq "parse throughput" 49998.50 "$(kv_get "$b/wl.env" THROUGHPUT)"
  t_eq "parse p99" 0.160768 "$(kv_get "$b/wl.env" P99_MS)"
  t_eq "disk reads delta" 6000000 "$(kv_get "$b/wl.env" FIO_DISK_READS_DELTA)"
  t_eq "disk writes delta" 30 "$(kv_get "$b/wl.env" FIO_DISK_WRITES_DELTA)"
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

# --- schema: fio constants are frozen, columns unchanged ---
mkdir -p "$T/s"
LADDER="1:10000" _schema_freeze "$T/s" perf
grep -q '"fio_numjobs": 4' "$T/s/schema.json" && ok || bad "schema lacks fio_numjobs"
grep -q '"fio_rw": "randread"' "$T/s/schema.json" && ok || bad "schema lacks fio_rw"

printf 'fio tests: %s passed, %s failed\n' "$NPASS" "$NFAIL"
(( NFAIL == 0 ))
