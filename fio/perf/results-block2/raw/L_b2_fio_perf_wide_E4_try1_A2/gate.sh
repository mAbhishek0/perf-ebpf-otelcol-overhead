#!/bin/sh
# gate.sh — fio exec_prerun for each measure job: say "waiting", then wait
# for the harness's go. The marker holds its arrival time in ns (GATE_WAIT_S). Bounded, so a dead harness cannot leave fio hanging.
date +%s%N > "/home/ab/Downloads/perf-ebpf-otelcol-overhead/fio/perf/results-block2/raw/L_b2_fio_perf_wide_E4_try1_A2/ready.$$"
n=0
while [ ! -e "/home/ab/Downloads/perf-ebpf-otelcol-overhead/fio/perf/results-block2/raw/L_b2_fio_perf_wide_E4_try1_A2/go" ]; do
  n=$((n + 1))
  [ $n -le 6000 ] || exit 1
  sleep 0.05
done
