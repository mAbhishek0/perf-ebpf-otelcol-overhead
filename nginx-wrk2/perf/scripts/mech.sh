# mech.sh — perf plugin for the nginx pair. Sourced.
# All logic is in common/mech/perf.sh (shared by every workload). nginx's
# narrow target is its worker PIDs, which wl_start writes to target_pids.
PERF_TARGET_DESC="nginx worker PIDs"
source "$LAPTOP_ROOT/common/mech/perf.sh"
