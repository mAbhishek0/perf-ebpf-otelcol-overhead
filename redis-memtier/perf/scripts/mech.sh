# mech.sh — perf plugin for the redis pair. Sourced.
# All logic is in common/mech/perf.sh (shared by every workload).
# Narrow (plan R12): perf.sh reads $b/target_pids and runs
#   perf record -F 99 -g -p <target_pids>
# (common/mech/perf.sh, case narrow). redis's wl_start writes the single
# redis-server PID there (checked against /proc/<pid>/comm). `perf record -p
# PID` is per-process: it opens an event on every thread (tid) that exists in
# that process at attach, and redis-server's I/O threads (and bio threads) are
# started at boot, before any tracer attaches, so all its threads are covered.
# Wide (R12): unchanged from every pair — workload CPUs, 999 Hz, plus perf trace.
PERF_TARGET_DESC="redis-server PID (all its threads)"
source "$LAPTOP_ROOT/common/mech/perf.sh"
