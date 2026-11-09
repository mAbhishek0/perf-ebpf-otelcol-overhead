# mech.sh — perf plugin for the fio pair. Sourced.
# All logic is in common/mech/perf.sh. fio's narrow target is the fio
# process (target_pids, written by wl_ramp); by attach time its measure-job
# threads already exist (they wait at the gate), so perf -p records them.
PERF_TARGET_DESC="fio process PID"
source "$LAPTOP_ROOT/common/mech/perf.sh"
