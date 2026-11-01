#!/usr/bin/env bash
# probe_laptop.sh — one-shot Platform L probe, run before any benchmark script
# is written for this machine.
#
# Goal: extract every fact about this laptop needed to decide whether it can
# run all three workloads (nginx-wrk2, fio, redis-memtier) under all three
# monitoring systems (perf, eBPF/BCC, OpenTelemetry collector), and to write
# those nine benchmark scripts for it. Extraction is the point; the PASS/WARN/
# FAIL verdicts and the 3x3 matrix are a first-pass summary of the same data,
# and the raw dump is there so the decision can be re-made without re-probing.
#
# It changes nothing on the host. The only write outside its output directory
# is a 4 KiB O_DIRECT probe file in $FIO_DIR, deleted immediately.
#
# Usage:   sudo ./probe_laptop.sh            # full probe (root sees PMU, BPF, tracefs)
#          ./probe_laptop.sh                 # partial; root-only checks report WARN
#          FIO_DIR=/mnt/scratch sudo ./probe_laptop.sh   # probe a different fio target
#
# Output (in laptop/probe/, named by hostname so two machines never collide):
#   laptop_profile_<host>.env    flat KEY='value' lines. Machine-readable, and
#                                sourceable by the benchmark scripts, so they
#                                read the probed topology instead of
#                                hard-coding it. Diffable across re-probes.
#   laptop_readiness_<host>.txt  human-readable report: every check as
#                                PASS/WARN/FAIL/INSTALL with a reason, then
#                                the 3x3 readiness matrix.
#   laptop_raw_<host>.txt        unfiltered output of every relevant command
#                                and sysfs/procfs file, one titled block each.
# Missing programs are reported as INSTALL, never as blockers: a cell is
# NOT-READY only for hardware, firmware or kernel facts no package can fix.
# Exit status: 0 if no cell is NOT-READY (installs may still be pending), 1 otherwise.

set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/probe"
HOST="$(hostname -s 2>/dev/null || hostname)"
ENV_OUT="${OUT_DIR}/laptop_profile_${HOST}.env"
TXT_OUT="${OUT_DIR}/laptop_readiness_${HOST}.txt"
RAW_OUT="${OUT_DIR}/laptop_raw_${HOST}.txt"
FIO_DIR="${FIO_DIR:-/var/tmp}"
FIO_MIN_FREE_GB=20        # fio file + headroom; results/ and perf.data share the disk
NGINX_PORT=8080           # matches the Platform S config.env
REDIS_PORT=6379
OTELCOL_PORT=18888
NEEDED_CPUS=8             # 4 workload + 2 aggregator + 2 generator

mkdir -p "$OUT_DIR"
: > "$ENV_OUT"
: > "$TXT_OUT"
: > "$RAW_OUT"

# ---------- output helpers ----------
kv() {  # kv KEY value...  -> KEY='value' (single-quoted, so sourcing never expands it)
  local k="$1"; shift
  local v="$*"
  v="$(printf '%s' "$v" | tr '\n' ' ' | tr -d "'" | sed 's/ *$//')"
  printf "%s='%s'\n" "$k" "$v" >> "$ENV_OUT"
}
say() { printf '%s\n' "$*" | tee -a "$TXT_OUT"; }
section() { say ""; say "===== $1 ====="; }

# Per-target failure lists. Targets: base perf ebpf collector nginx fio redis.
declare -A FAILS=()
check() {  # check PASS|WARN|FAIL target "message"
  local lvl="$1" tgt="$2" msg="$3"
  say "  [$lvl] ($tgt) $msg"
  if [[ "$lvl" == FAIL ]]; then FAILS[$tgt]="${FAILS[$tgt]:-}${msg}; "; fi
}
# A missing program is not a blocker — it can be installed. `need` records it
# on a separate list, so the matrix can tell "install X first" apart from a
# hardware or kernel fact that no package fixes.
declare -A NEEDS=()
need() {  # need target "what is missing (and how to install it)"
  say "  [INSTALL] ($1) $2"
  NEEDS[$1]="${NEEDS[$1]:-}$2; "
}
have() { command -v "$1" >/dev/null 2>&1; }
rd() { [[ -r "$1" ]] && tr -d '\n' < "$1" 2>/dev/null || echo "n/a"; }

IS_ROOT=false; [[ $EUID -eq 0 ]] && IS_ROOT=true

say "Platform L probe — $(date -Is) — host $HOST — root=$IS_ROOT"
kv PROBE_DATE "$(date -Is)"
kv PROBE_AS_ROOT "$IS_ROOT"
kv HOSTNAME "$HOST"

# ---------- 1. identity / OS ----------
section "1. identity and OS"
OS_PRETTY="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
KREL="$(uname -r)"
kv OS "$OS_PRETTY"; kv KERNEL "$KREL"; kv ARCH "$(uname -m)"
say "  OS $OS_PRETTY, kernel $KREL, $(uname -m)"
VIRT="$(systemd-detect-virt 2>/dev/null)"; VIRT="${VIRT:-none}"  # prints "none" AND exits 1 on bare metal
kv VIRT "$VIRT"
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  kv WSL true
  check FAIL base "running under WSL — PMU, SMT and boost controls are not the laptop's; run on bare-metal Linux"
elif [[ "$VIRT" != none ]]; then
  kv WSL false
  check FAIL base "virtualised ($VIRT) — measurements would describe the hypervisor, not the laptop"
else
  kv WSL false
  check PASS base "bare metal"
fi
$IS_ROOT || check WARN base "not root — PMU, BPF and tracefs checks below may under-report; re-run with sudo"
kv BOOT_CMDLINE "$(cat /proc/cmdline)"
for p in isolcpus nohz_full rcu_nocbs mitigations intel_pstate amd_pstate; do
  grep -qw "$p" /proc/cmdline && say "  cmdline has $p"
done

# ---------- 2. CPU topology ----------
section "2. CPU topology"
have lscpu || need base "lscpu missing (util-linux)"
CPU_MODEL="$(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | head -1)"
VENDOR="$(lscpu 2>/dev/null | sed -n 's/^Vendor ID: *//p' | head -1)"
ONLINE="$(rd /sys/devices/system/cpu/online)"
NCPU_ONLINE="$(getconf _NPROCESSORS_ONLN)"
SOCKETS="$(lscpu -p=SOCKET 2>/dev/null | grep -v '^#' | sort -u | wc -l)"
PHYS_CORES="$(lscpu -p=CORE,SOCKET 2>/dev/null | grep -v '^#' | sort -u | wc -l)"
NUMA_NODES="$(lscpu -p=NODE 2>/dev/null | grep -v '^#' | sort -u | wc -l)"
kv CPU_VENDOR "$VENDOR"; kv CPU_MODEL "$CPU_MODEL"; kv CPUS_ONLINE "$ONLINE"
kv NCPU_ONLINE "$NCPU_ONLINE"; kv SOCKETS "$SOCKETS"; kv PHYSICAL_CORES "$PHYS_CORES"
kv NUMA_NODES "$NUMA_NODES"
say "  $CPU_MODEL — $SOCKETS socket, $PHYS_CORES physical cores, $NCPU_ONLINE logical online ($ONLINE), $NUMA_NODES NUMA node(s)"

# Hybrid (Intel P/E) detection: core types differ in IPC and max clock, so a
# cpuset that straddles them is not a uniform resource.
HYBRID=false; P_CPUS=""; E_CPUS=""
if [[ -r /sys/devices/cpu_core/cpus && -r /sys/devices/cpu_atom/cpus ]]; then
  HYBRID=true; P_CPUS="$(rd /sys/devices/cpu_core/cpus)"; E_CPUS="$(rd /sys/devices/cpu_atom/cpus)"
fi
kv CPU_HYBRID "$HYBRID"; kv CPU_P_CORES "$P_CPUS"; kv CPU_E_CORES "$E_CPUS"
if $HYBRID; then
  check WARN base "hybrid CPU: P-cores $P_CPUS, E-cores $E_CPUS — cpusets must not mix types"
else
  check PASS base "homogeneous cores"
fi
# Per-CPU map: logical cpu -> core, socket, node, max MHz. One line per CPU.
lscpu -e=CPU,CORE,SOCKET,NODE,MAXMHZ,ONLINE 2>/dev/null | sed 's/^/  /' | tee -a "$TXT_OUT"
kv CPU_MAP "$(lscpu -p=CPU,CORE,SOCKET,NODE,MAXMHZ 2>/dev/null | grep -v '^#' | tr '\n' ' ')"
# L3 sharing: which CPUs share a last-level cache.
L3="$(for c in /sys/devices/system/cpu/cpu[0-9]*/cache/index3/shared_cpu_list; do cat "$c" 2>/dev/null; done | sort -u | tr '\n' ' ')"
kv L3_SHARED_GROUPS "$L3"; say "  L3 sharing groups: ${L3:-n/a}"

SMT_CTRL="$(rd /sys/devices/system/cpu/smt/control)"
SMT_ACTIVE="$(rd /sys/devices/system/cpu/smt/active)"
kv SMT_CONTROL "$SMT_CTRL"; kv SMT_ACTIVE "$SMT_ACTIVE"
case "$SMT_CTRL" in
  on|off) check PASS base "SMT control writable (now $SMT_CTRL, active=$SMT_ACTIVE)" ;;
  notsupported) check PASS base "no SMT on this CPU" ;;
  forceoff) check PASS base "SMT force-disabled" ;;
  *) check WARN base "SMT control is '$SMT_CTRL' — cannot be switched at runtime" ;;
esac
# Usable CPUs with SMT off = physical cores (non-hybrid E-cores have no SMT anyway).
kv CPUS_IF_SMT_OFF "$PHYS_CORES"
if (( PHYS_CORES >= NEEDED_CPUS )); then
  check PASS base "$PHYS_CORES physical cores >= $NEEDED_CPUS needed (4 workload + 2 aggregator + 2 generator)"
else
  check FAIL base "$PHYS_CORES physical cores < $NEEDED_CPUS needed for the 4+2+2 layout with SMT off"
fi

# ---------- 3. frequency, boost, power, thermals ----------
section "3. frequency, boost, power, thermals"
CF=/sys/devices/system/cpu/cpu0/cpufreq
DRIVER="$(rd $CF/scaling_driver)"; GOV="$(rd $CF/scaling_governor)"
GOVS="$(rd $CF/scaling_available_governors)"; EPP="$(rd $CF/energy_performance_preference)"
kv CPUFREQ_DRIVER "$DRIVER"; kv GOVERNOR "$GOV"; kv GOVERNORS_AVAILABLE "$GOVS"; kv EPP "$EPP"
kv CPU_MIN_KHZ "$(rd $CF/cpuinfo_min_freq)"; kv CPU_MAX_KHZ "$(rd $CF/cpuinfo_max_freq)"
kv CPU_BASE_KHZ "$(rd $CF/base_frequency)"
say "  driver $DRIVER, governor $GOV (available: $GOVS), EPP $EPP"
[[ "$GOVS" == *performance* ]] && check PASS base "performance governor available" \
  || check FAIL base "performance governor not available"
BOOST_PATH=""; BOOST_VAL=""
if [[ -e /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
  BOOST_PATH=/sys/devices/system/cpu/intel_pstate/no_turbo; BOOST_VAL="no_turbo=$(rd $BOOST_PATH)"
elif [[ -e /sys/devices/system/cpu/cpufreq/boost ]]; then
  BOOST_PATH=/sys/devices/system/cpu/cpufreq/boost; BOOST_VAL="boost=$(rd $BOOST_PATH)"
elif [[ -e $CF/boost ]]; then
  BOOST_PATH=$CF/boost; BOOST_VAL="boost=$(rd $BOOST_PATH) (per-policy)"
fi
kv BOOST_CONTROL_PATH "$BOOST_PATH"; kv BOOST_STATE "$BOOST_VAL"
[[ -n "$BOOST_PATH" ]] && check PASS base "boost control at $BOOST_PATH ($BOOST_VAL)" \
  || check FAIL base "no boost control found — clock would float with temperature"
kv INTEL_PSTATE_STATUS "$(rd /sys/devices/system/cpu/intel_pstate/status)"
kv AMD_PSTATE_STATUS "$(rd /sys/devices/system/cpu/amd_pstate/status)"

AC="unknown"
for ps in /sys/class/power_supply/*; do
  [[ "$(rd "$ps/type")" == Mains ]] && AC="$(rd "$ps/online")"
done
kv AC_ONLINE "$AC"
case "$AC" in
  1) check PASS base "on AC power" ;;
  0) check FAIL base "on battery — firmware caps clocks; plug in before benchmarking" ;;
  *) check WARN base "AC state unknown" ;;
esac
kv PLATFORM_PROFILE "$(rd /sys/firmware/acpi/platform_profile)"
kv PLATFORM_PROFILE_CHOICES "$(rd /sys/firmware/acpi/platform_profile_choices)"
say "  platform profile: $(rd /sys/firmware/acpi/platform_profile) (choices: $(rd /sys/firmware/acpi/platform_profile_choices))"
TMAX=0
for z in /sys/class/thermal/thermal_zone*/temp; do
  t="$(cat "$z" 2>/dev/null || echo 0)"; (( t > TMAX )) && TMAX=$t
done
kv THERMAL_MAX_MILLIC "$TMAX"; say "  hottest thermal zone now: $((TMAX/1000)) C"
(( TMAX > 80000 )) && check WARN base "already above 80 C at idle — expect throttling under load"
have powerprofilesctl && kv POWER_PROFILES_DAEMON "$(powerprofilesctl get 2>/dev/null)"
# Installed-but-stopped TLP is fine; only an active one rewrites governor/boost.
if systemctl is-active --quiet tlp 2>/dev/null; then
  check WARN base "TLP active — it rewrites governor/boost on AC events; systemctl stop tlp before runs"
elif have tlp-stat; then
  say "  TLP installed but not active"
fi

# ---------- 4. memory ----------
section "4. memory"
MEM_KB="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
SWAP_KB="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
kv MEM_TOTAL_KB "$MEM_KB"; kv SWAP_TOTAL_KB "$SWAP_KB"
kv THP "$(rd /sys/kernel/mm/transparent_hugepage/enabled)"
kv SWAPPINESS "$(rd /proc/sys/vm/swappiness)"
say "  RAM $((MEM_KB/1024/1024)) GiB, swap $((SWAP_KB/1024/1024)) GiB, THP $(rd /sys/kernel/mm/transparent_hugepage/enabled)"
(( MEM_KB >= 8*1024*1024 )) && check PASS base "RAM >= 8 GiB" \
  || check WARN base "RAM < 8 GiB — redis dataset and fio file must be sized down"

# ---------- 5. noise sources ----------
section "5. background load"
kv LOADAVG "$(cut -d' ' -f1-3 /proc/loadavg)"
say "  loadavg $(cut -d' ' -f1-3 /proc/loadavg)"
say "  top CPU consumers:"
ps -eo pcpu,comm --sort=-pcpu 2>/dev/null | head -6 | sed 's/^/    /' | tee -a "$TXT_OUT"
# pgrep patterns are already extended regex; it has no -E flag (passing one
# made pgrep error out, so this check silently never fired).
GUI=false; pgrep -x 'gnome-shell|kwin_wayland|kwin_x11|Xorg|Xwayland|sway' >/dev/null 2>&1 && GUI=true
kv GUI_SESSION "$GUI"
$GUI && check WARN base "graphical session running — run from a TTY or ssh with the desktop stopped"
# Desktop indexers and browsers are the usual noise; the file indexer also
# does disk IO, which lands directly on fio.
NOISY="$(pgrep -l -x 'localsearch-ext|localsearch-3|tracker-miner-fs-3|tracker-extract-3|firefox|chrome|brave|Telegram|gnome-software|fwupd' 2>/dev/null | awk '{print $2}' | sort -u | tr '
' ' ')"
kv NOISY_PROCESSES "$NOISY"
[[ -n "$NOISY" ]] && check WARN base "noisy processes running: $NOISY— close/stop them before measured runs"
for s in irqbalance thermald tlp auto-cpufreq power-profiles-daemon; do
  systemctl is-active --quiet "$s" 2>/dev/null && say "  service active: $s"
done
kv ACTIVE_TUNING_SERVICES "$(for s in irqbalance thermald tlp auto-cpufreq power-profiles-daemon; do systemctl is-active --quiet "$s" 2>/dev/null && printf '%s ' "$s"; done)"

# ---------- 6. kernel config relevant to tracing ----------
section "6. kernel config"
KCONF=""
if [[ -r /boot/config-$KREL ]]; then KCONF="$(cat "/boot/config-$KREL")"
elif [[ -r /proc/config.gz ]]; then KCONF="$(zcat /proc/config.gz)"; fi
kconf() { local v; v="$(grep -E "^$1=" <<<"$KCONF" | cut -d= -f2)"; echo "${v:-n}"; }
if [[ -z "$KCONF" ]]; then
  check WARN ebpf "kernel config not readable — BPF options unverified"
else
  for o in CONFIG_BPF_SYSCALL CONFIG_BPF_JIT CONFIG_BPF_EVENTS CONFIG_KPROBES CONFIG_UPROBES \
           CONFIG_UPROBE_EVENTS CONFIG_FTRACE_SYSCALLS CONFIG_DEBUG_INFO_BTF CONFIG_PERF_EVENTS \
           CONFIG_CGROUP_BPF CONFIG_IKHEADERS; do
    val="$(kconf "$o")"; kv "$o" "$val"; say "  $o=$val"
  done
  for o in CONFIG_BPF_SYSCALL CONFIG_BPF_EVENTS CONFIG_KPROBES CONFIG_UPROBES; do
    [[ "$(kconf "$o")" == y ]] || check FAIL ebpf "$o not enabled"
  done
  [[ "$(kconf CONFIG_PERF_EVENTS)" == y ]] || check FAIL perf "CONFIG_PERF_EVENTS not enabled"
  [[ "$(kconf CONFIG_FTRACE_SYSCALLS)" == y ]] || check FAIL perf "CONFIG_FTRACE_SYSCALLS off — no syscall tracepoints"
fi
BTF=false; [[ -r /sys/kernel/btf/vmlinux ]] && BTF=true
HEADERS=false; [[ -d /lib/modules/$KREL/build ]] && HEADERS=true
kv BTF_VMLINUX "$BTF"; kv KERNEL_HEADERS "$HEADERS"
$HEADERS && check PASS ebpf "kernel headers present (/lib/modules/$KREL/build)" \
  || need ebpf "kernel headers missing — BCC compiles against them (apt install linux-headers-$KREL)"
LOCKDOWN="$(rd /sys/kernel/security/lockdown)"; kv LOCKDOWN "$LOCKDOWN"
case "$LOCKDOWN" in
  *"[confidentiality]"*) check FAIL ebpf "kernel lockdown=confidentiality blocks BPF kernel reads (Secure Boot)" ;;
  *"[integrity]"*) check WARN ebpf "kernel lockdown=integrity (Secure Boot) — kprobe/uprobe reads OK, some BPF helpers denied" ;;
  *) check PASS ebpf "kernel lockdown none/unknown ($LOCKDOWN)" ;;
esac
SB="unknown"; have mokutil && SB="$(mokutil --sb-state 2>/dev/null | head -1)"; kv SECURE_BOOT "$SB"

# ---------- 7. perf ----------
section "7. perf"
PARANOID="$(rd /proc/sys/kernel/perf_event_paranoid)"; KPTR="$(rd /proc/sys/kernel/kptr_restrict)"
kv PERF_EVENT_PARANOID "$PARANOID"; kv KPTR_RESTRICT "$KPTR"
say "  perf_event_paranoid=$PARANOID kptr_restrict=$KPTR"
if have perf && perf version >/dev/null 2>&1; then
  PV="$(perf version 2>&1)"; kv PERF_VERSION "$PV"
  KMAJ="$(echo "$KREL" | grep -oE '^[0-9]+\.[0-9]+')"
  [[ "$PV" == *"$KMAJ"* ]] && kv PERF_KERNEL_MATCH true || kv PERF_KERNEL_MATCH false
  check PASS perf "$PV (kernel $KMAJ)"
  PS="$(perf stat -e cycles,instructions -- true 2>&1)"
  if grep -qE 'not supported|not counted|Permission|Error' <<<"$PS"; then
    kv PERF_HW_COUNTERS false
    check FAIL perf "hardware counters unavailable: $(grep -m1 -E 'not supported|not counted|Permission|Error' <<<"$PS" | sed 's/^ *//')"
  else
    kv PERF_HW_COUNTERS true; check PASS perf "cycles/instructions counters work"
  fi
  if perf record -F 99 -g -o /dev/null -- true >/dev/null 2>&1; then
    check PASS perf "perf record -g works"
  else
    check FAIL perf "perf record -g failed"
  fi
else
  kv PERF_VERSION missing
  need perf "perf missing or not matching kernel (apt install linux-tools-$KREL linux-tools-common)"
fi
TRACEFS=""
for t in /sys/kernel/tracing /sys/kernel/debug/tracing; do [[ -r $t/events ]] && TRACEFS=$t && break; done
kv TRACEFS "$TRACEFS"
if [[ -n "$TRACEFS" ]]; then
  NSYS="$(ls -d "$TRACEFS"/events/syscalls/sys_enter_* 2>/dev/null | wc -l)"
  kv SYSCALL_TRACEPOINTS "$NSYS"
  for tp in syscalls/sys_enter_accept4 syscalls/sys_enter_epoll_wait syscalls/sys_enter_io_uring_enter \
            syscalls/sys_enter_pwrite64 block/block_rq_issue block/block_rq_complete sched/sched_switch; do
    [[ -d "$TRACEFS/events/$tp" ]] && say "  tracepoint ok: $tp" || say "  tracepoint MISSING: $tp"
  done
  (( NSYS > 0 )) && check PASS perf "$NSYS syscall tracepoints in $TRACEFS" \
    || check FAIL perf "no syscall tracepoints"
else
  check FAIL perf "tracefs not readable (root needed, or mount tracefs)"
fi

# ---------- 8. eBPF tooling ----------
section "8. eBPF"
kv BPF_JIT_ENABLE "$(rd /proc/sys/net/core/bpf_jit_enable)"
kv UNPRIV_BPF_DISABLED "$(rd /proc/sys/kernel/unprivileged_bpf_disabled)"
kv BPF_STATS_ENABLED "$(rd /proc/sys/kernel/bpf_stats_enabled)"
PY="$(command -v python3 || true)"; kv PYTHON3 "${PY:-missing}"
if [[ -n "$PY" ]]; then
  BCCV="$(python3 -c 'import bcc,sys; print(getattr(bcc,"__version__","unknown"))' 2>/dev/null || true)"
  kv BCC_PYTHON "${BCCV:-missing}"
  [[ -n "$BCCV" ]] && check PASS ebpf "python3 bcc $BCCV importable" \
    || need ebpf "python3 cannot import bcc (apt install bpfcc-tools python3-bpfcc)"
  if [[ -n "$BCCV" ]] && $IS_ROOT; then
    if python3 - >/dev/null 2>&1 <<'PYEOF'
from bcc import BPF
b = BPF(text='TRACEPOINT_PROBE(syscalls, sys_enter_getpid) { return 0; }')
b.cleanup()
PYEOF
    then check PASS ebpf "BCC compiled and loaded a tracepoint program"
    else check FAIL ebpf "BCC could not compile/load a trivial tracepoint program"; fi
  fi
else
  kv BCC_PYTHON missing; need ebpf "python3 missing"
fi
have bpftrace && kv BPFTRACE_VERSION "$(bpftrace --version 2>&1)" || kv BPFTRACE_VERSION missing
have bpftool && kv BPFTOOL_VERSION "$(bpftool version 2>&1 | head -1)" || kv BPFTOOL_VERSION missing
say "  bpftrace: $(have bpftrace && bpftrace --version 2>&1 || echo missing); bpftool: $(have bpftool && echo present || echo missing)"

# ---------- 9. containers and cgroups ----------
section "9. containers and cgroups"
CG2=false; [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" == cgroup2fs ]] && CG2=true
kv CGROUP_V2 "$CG2"
CTRLS="$(rd /sys/fs/cgroup/cgroup.controllers)"; kv CGROUP_CONTROLLERS "$CTRLS"
$CG2 && [[ "$CTRLS" == *cpuset* ]] && check PASS base "cgroup v2 with cpuset controller" \
  || check FAIL base "cgroup v2 cpuset controller not available"
have taskset && check PASS base "taskset present" || need base "taskset missing (util-linux)"
if have docker && docker info >/dev/null 2>&1; then
  kv DOCKER_VERSION "$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  kv DOCKER_CGROUP_DRIVER "$(docker info --format '{{.CgroupDriver}}' 2>/dev/null)"
  check PASS base "docker daemon reachable ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"
  for img in nginx:1.24 redis:7.4; do
    docker image inspect "$img" >/dev/null 2>&1 && say "  image cached: $img" || say "  image not cached: $img"
  done
else
  kv DOCKER_VERSION missing
  need base "docker missing or daemon unreachable (apt install docker.io; systemctl start docker; add user to docker group)"
fi

# ---------- 10. workload tooling ----------
section "10. workload tools"
toolver() {  # toolver KEY binary version-args...
  local key="$1" bin="$2"; shift 2
  if have "$bin"; then kv "$key" "$("$bin" "$@" 2>&1 | head -1)"; return 0; fi
  kv "$key" missing; return 1
}
# nginx-wrk2: wrk2 is giltene/wrk2; its binary is often still called "wrk".
# Only the fork has -R (constant-throughput), which the rate ladder depends on.
WRK2=""
for b in wrk2 wrk; do
  if have "$b" && "$b" 2>&1 | grep -qE -- '-R, --rate'; then WRK2="$(command -v "$b")"; break; fi
done
kv WRK2_BINARY "${WRK2:-missing}"
[[ -n "$WRK2" ]] && check PASS nginx "wrk2 (with -R) at $WRK2" \
  || need nginx "wrk2 with -R not found (plain wrk cannot hold a fixed rate; build giltene/wrk2)"
toolver NGINX_HOST_VERSION nginx -v || true
# fio
if toolver FIO_VERSION fio --version; then
  ENG="$(fio --enghelp 2>&1 | tr -s ' \t\n' ' ')"; kv FIO_ENGINES "$ENG"
  [[ "$ENG" == *libaio* ]] && check PASS fio "fio $(fio --version) with libaio" \
    || need fio "fio lacks libaio engine"
  [[ "$ENG" == *io_uring* ]] && say "  fio io_uring engine available" || say "  fio io_uring engine absent"
else
  need fio "fio missing (apt install fio)"
fi
# redis-memtier
toolver REDIS_SERVER_VERSION redis-server --version \
  && check PASS redis "redis-server present" \
  || check WARN redis "redis-server not on host (fine if run from the redis docker image)"
toolver MEMTIER_VERSION memtier_benchmark --version \
  && check PASS redis "memtier_benchmark present" \
  || need redis "memtier_benchmark missing (apt install memtier-benchmark or build from RedisLabs/memtier_benchmark)"
toolver REDIS_CLI_VERSION redis-cli --version || true
# collector
OTEL=""
for b in /opt/otelcol/otelcol-contrib otelcol-contrib; do
  if [[ -x "$b" ]] || have "$b"; then OTEL="$b"; break; fi
done
if [[ -n "$OTEL" ]]; then
  kv OTELCOL_BINARY "$OTEL"; kv OTELCOL_VERSION "$("$OTEL" --version 2>&1 | head -1)"
  check PASS collector "otelcol-contrib at $OTEL ($("$OTEL" --version 2>&1 | head -1))"
else
  kv OTELCOL_BINARY missing
  need collector "otelcol-contrib missing (server uses /opt/otelcol/otelcol-contrib 0.161.0)"
fi
# Helpers the pipeline uses for accounting and retention.
for t in zstd jq pidstat mpstat cpupower numactl turbostat stress-ng iostat; do
  if have "$t"; then kv "TOOL_${t//-/_}" present; else kv "TOOL_${t//-/_}" missing; say "  helper missing: $t"; fi
done
have zstd || check WARN base "zstd missing — perf.data retention falls back to gzip"
have pidstat || check WARN base "pidstat (sysstat) missing — per-process CPU attribution unavailable"

# Ports the workloads and collector bind.
for p in $NGINX_PORT $REDIS_PORT $OTELCOL_PORT; do
  if ss -ltnH "sport = :$p" 2>/dev/null | grep -q .; then
    check FAIL base "port $p already in use"
  else
    say "  port $p free"
  fi
done

# ---------- 11. storage for fio ----------
section "11. storage (fio target $FIO_DIR)"
lsblk -d -o NAME,MODEL,SIZE,ROTA,TRAN,TYPE 2>/dev/null | sed 's/^/  /' | tee -a "$TXT_OUT"
if [[ -d "$FIO_DIR" ]]; then
  FS_TYPE="$(findmnt -no FSTYPE --target "$FIO_DIR" 2>/dev/null || stat -fc %T "$FIO_DIR")"  # stat -f reports ext4 as ext2/ext3
  SRC="$(df --output=source "$FIO_DIR" | tail -1)"
  FREE_GB="$(df -BG --output=avail "$FIO_DIR" | tail -1 | tr -dc 0-9)"
  DEV="$(lsblk -no PKNAME "$SRC" 2>/dev/null | head -1)"; DEV="${DEV:-$(basename "$SRC")}"
  kv FIO_DIR "$FIO_DIR"; kv FIO_FS_TYPE "$FS_TYPE"; kv FIO_SOURCE "$SRC"; kv FIO_DEVICE "$DEV"
  kv FIO_FREE_GB "$FREE_GB"
  kv FIO_DEVICE_ROTATIONAL "$(rd /sys/block/$DEV/queue/rotational)"
  kv FIO_DEVICE_SCHEDULER "$(rd /sys/block/$DEV/queue/scheduler)"
  kv FIO_DEVICE_MODEL "$(rd /sys/block/$DEV/device/model)"
  say "  $FIO_DIR on $SRC ($FS_TYPE), device $DEV, ${FREE_GB} GB free, scheduler $(rd /sys/block/$DEV/queue/scheduler)"
  (( FREE_GB >= FIO_MIN_FREE_GB )) && check PASS fio "${FREE_GB} GB free >= ${FIO_MIN_FREE_GB} GB" \
    || check FAIL fio "${FREE_GB} GB free < ${FIO_MIN_FREE_GB} GB on $FIO_DIR"
  [[ "$FS_TYPE" == tmpfs ]] && check FAIL fio "$FIO_DIR is tmpfs — fio would measure RAM, not the disk"
  [[ "$SRC" == /dev/mapper/* ]] && check WARN fio "$FIO_DIR is on device-mapper (LUKS/LVM?) — encryption adds CPU to every IO; record it"
  T="$FIO_DIR/.probe_odirect_$$"
  if dd if=/dev/zero of="$T" bs=4k count=1 oflag=direct status=none 2>/dev/null; then
    kv FIO_O_DIRECT true; check PASS fio "O_DIRECT writes work on $FIO_DIR"
  else
    kv FIO_O_DIRECT false; check FAIL fio "O_DIRECT not supported on $FIO_DIR — page cache would hide the device"
  fi
  rm -f "$T"
else
  check FAIL fio "FIO_DIR $FIO_DIR does not exist"
fi

# ---------- 12. raw dump ----------
# Everything below goes to $RAW_OUT unfiltered. Each block is titled with the
# exact command, so a missing tool shows as "command not found" rather than as
# a silent gap.
section "12. raw dump -> $RAW_OUT"
dump() {  # dump 'shell command'
  { printf '\n##### %s\n' "$1"; bash -c "$1" 2>&1 || true; } >> "$RAW_OUT"
}
dumpf() {  # dumpf file...  (sysfs/procfs files, one block each)
  local f; for f in "$@"; do [[ -r "$f" ]] && dump "cat $f"; done
}
# machine identity: model and BIOS decide firmware power behaviour
dumpf /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name \
      /sys/class/dmi/id/product_version /sys/class/dmi/id/bios_version /sys/class/dmi/id/bios_date
dump 'uname -a'; dump 'cat /etc/os-release'; dump 'cat /proc/cmdline'
# CPU: topology, flags, microcode, per-CPU frequency limits, idle states
dump 'lscpu'; dump 'lscpu -e=CPU,NODE,SOCKET,CORE,CACHE,ONLINE,MAXMHZ,MINMHZ'
dump 'lscpu --caches'; dump 'numactl --hardware'
dump 'grep -m1 "^flags" /proc/cpuinfo; grep -m1 microcode /proc/cpuinfo'
dump 'for c in /sys/devices/system/cpu/cpu[0-9]*; do printf "%s " ${c##*/}; for f in cpuinfo_min_freq cpuinfo_max_freq scaling_min_freq scaling_max_freq scaling_governor energy_performance_preference; do printf "%s=%s " $f "$(cat $c/cpufreq/$f 2>/dev/null)"; done; echo; done'
dump 'for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do echo ${s##*/} $(cat $s/name) latency=$(cat $s/latency)us disable=$(cat $s/disable); done'
dump 'grep . /sys/devices/system/cpu/intel_pstate/* /sys/devices/system/cpu/amd_pstate/* 2>/dev/null'
# Mitigations change syscall cost, which is most of what the tracers add to.
dump 'grep . /sys/devices/system/cpu/vulnerabilities/*'
dump 'grep . /sys/devices/system/clocksource/clocksource0/*_clocksource'
# power and energy: RAPL would let a later arm measure energy, not just CPU
dump 'grep . /sys/class/power_supply/*/type /sys/class/power_supply/*/online /sys/class/power_supply/*/status /sys/class/power_supply/*/capacity 2>/dev/null'
dump 'ls /sys/class/powercap/; grep . /sys/class/powercap/*/name'
dump 'for z in /sys/class/thermal/thermal_zone*; do echo $(cat $z/type) $(cat $z/temp); done'
dump 'turbostat --quiet --show Core,CPU,Busy%,Bzy_MHz,PkgTmp,PkgWatt --interval 1 --num_iterations 3'
# memory
dump 'cat /proc/meminfo'
dump 'dmidecode -t memory | grep -E "Size|Speed|Type:|Locator" | grep -v "No Module"'
dump 'grep . /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag'
# sysctls the workloads and tracers are sensitive to
dump 'sysctl kernel.perf_event_paranoid kernel.perf_event_max_sample_rate kernel.perf_cpu_time_max_percent kernel.kptr_restrict kernel.unprivileged_bpf_disabled kernel.bpf_stats_enabled net.core.bpf_jit_enable net.core.bpf_jit_harden kernel.nmi_watchdog kernel.sched_autogroup_enabled vm.overcommit_memory vm.swappiness vm.dirty_ratio vm.dirty_background_ratio net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.ipv4.ip_local_port_range net.ipv4.tcp_tw_reuse fs.file-max fs.nr_open'
dump 'ulimit -a'
# kernel config: every option the three tracers and the cpusets depend on
dump '{ cat /boot/config-$(uname -r) 2>/dev/null || zcat /proc/config.gz; } | grep -E "^CONFIG_(BPF|KPROBE|UPROBE|FTRACE|FUNCTION_TRACER|DYNAMIC_FTRACE|TRACEPOINTS|PERF_EVENTS|HW_PERF|DEBUG_INFO_BTF|IKHEADERS|CGROUP|CPUSETS|SCHED_|HZ|NO_HZ|PREEMPT|SECURITY_LOCKDOWN|LOCK_DOWN)"'
dump 'cat /sys/kernel/security/lockdown'; dump 'mokutil --sb-state'
dump 'lsmod | sort'
# perf: what the PMU exposes on this CPU
dump 'perf version --build-options'; dump 'perf list hw cache | head -60'
dump 'ls /sys/bus/event_source/devices/'; dump 'perf list "syscalls:*" | wc -l'
dump 'perf stat -a -e cycles,instructions,cache-misses,branch-misses,context-switches -- sleep 1'
# eBPF: the kernel feature probe is the definitive program/map/helper list
dump 'bpftool feature probe kernel | grep -v "^$" | head -400'
dump 'python3 -c "import bcc; print(bcc.__file__, getattr(bcc, \"__version__\", \"?\"))"'
dump 'bpftrace --info'; dump 'ls /sys/kernel/btf | head'
dump 'dpkg -l | grep -E "bpfcc|bcc|libbpf|bpftrace|linux-tools|linux-headers|linux-image"'
# containers and cgroups
dump 'docker info'; dump 'docker images'
dump 'grep . /sys/fs/cgroup/cgroup.controllers /sys/fs/cgroup/cgroup.subtree_control /sys/fs/cgroup/cpuset.cpus.effective'
dump 'systemctl --type=service --state=running --no-pager --no-legend'
# workload tools, and the binaries the eBPF probes would attach uprobes to
dump 'wrk2 2>&1 | head -25; wrk 2>&1 | head -25'
dump 'fio --version; fio --enghelp'
dump 'redis-server --version; memtier_benchmark --version'
dump '/opt/otelcol/otelcol-contrib --version; otelcol-contrib --version; otelcol-contrib components | head -80'
dump 'for b in nginx redis-server; do p=$(command -v $b) && file -L $p && nm -D $p | wc -l; done'
# storage: the fio target device in full
dump 'lsblk -o NAME,MODEL,SIZE,ROTA,TRAN,TYPE,FSTYPE,MOUNTPOINT,SCHED,PHY-SEC,LOG-SEC,MIN-IO,OPT-IO'
dump 'df -hT'; dump "findmnt -no SOURCE,FSTYPE,OPTIONS --target $FIO_DIR"
dump 'grep . /sys/block/*/queue/scheduler /sys/block/*/queue/nr_requests /sys/block/*/queue/rotational /sys/block/*/queue/write_cache'
dump 'nvme list'; dump "smartctl -i \$(df --output=source $FIO_DIR | tail -1)"
# network: loopback carries wrk2->nginx and memtier->redis
dump 'ip -br addr'; dump 'ip link show lo'; dump 'ss -ltnp'; dump 'ethtool -k lo | head -20'
# current noise
dump 'uptime'; dump 'ps -eo pid,pcpu,pmem,psr,comm --sort=-pcpu | head -25'
dump 'head -40 /proc/interrupts'
dump 'journalctl -k -b --no-pager | grep -iE "thrott|mce|hardware error|bpf|lockdown|perf" | tail -40'
say "  $(grep -c '^#####' "$RAW_OUT") raw blocks written"

# ---------- 13. readiness matrix ----------
section "13. readiness matrix (base + mechanism + workload)"
READY_ALL=true          # no hardware/kernel blocker anywhere (installs allowed)
INSTALL_FREE=true       # additionally, nothing left to install
say "  READY = runs now; INSTALL-FIRST = only missing programs; NOT-READY = hardware/kernel blocker"
say "  $(printf '%-14s %-16s %-16s %-16s' workload perf ebpf collector)"
for w in nginx fio redis; do
  row="$(printf '%-14s' "$w")"
  for m in perf ebpf collector; do
    if [[ -n "${FAILS[base]:-}${FAILS[$m]:-}${FAILS[$w]:-}" ]]; then
      cell=NOT-READY; READY_ALL=false
    elif [[ -n "${NEEDS[base]:-}${NEEDS[$m]:-}${NEEDS[$w]:-}" ]]; then
      cell=INSTALL-FIRST; INSTALL_FREE=false
    else
      cell=READY
    fi
    kv "READY_${w}_${m}" "$cell"
    row+="$(printf ' %-16s' "$cell")"
  done
  say "  $row"
done
say ""
for t in base perf ebpf collector nginx fio redis; do
  [[ -n "${FAILS[$t]:-}" ]] && say "  blocking ($t): ${FAILS[$t]}"
done
for t in base perf ebpf collector nginx fio redis; do
  [[ -n "${NEEDS[$t]:-}" ]] && say "  to install ($t): ${NEEDS[$t]}"
done
kv READY_ALL "$READY_ALL"
kv INSTALL_FREE "$INSTALL_FREE"
say ""
say "profile: $ENV_OUT"
say "report:  $TXT_OUT"
say "raw:     $RAW_OUT"
# Exit 1 only for a blocker no package fixes; missing programs alone exit 0.
$READY_ALL && exit 0 || exit 1
