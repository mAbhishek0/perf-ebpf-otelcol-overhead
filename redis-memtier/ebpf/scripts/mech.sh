# mech.sh — eBPF (BCC) plugin for the redis pair. Sourced.
# All logic is in common/mech/ebpf.sh and common/mech/bcc_tracer.py. The
# probes are redis_probes.c (decision R13, docs/plans/2026-11-11-redis-implementation.md):
#   narrow: a uprobe on redis-server's call(), one event per executed command,
#           in-kernel filter = the redis-server tgid (target_pids)
#   wide:   raw_syscalls on WORKLOAD_CPUS (byte-identical to nginx's and fio's)
EBPF_PROBES_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/redis_probes.c"

# The two constants a fallback changes (R13): if check.sh shows events per
# command far from 1.0 because LTO inlined call(), set REDIS_UPROBE_SYMBOL to
# processCommand (one event per received command) and label every result a
# deviation. The BPF function name on_call and everything else stay as is.
REDIS_SERVER_BIN_IN_IMAGE=/usr/local/bin/redis-server
REDIS_UPROBE_SYMBOL=call

# Preflight (R13): the image's redis-server must have a FUNC symbol named
# exactly $REDIS_UPROBE_SYMBOL. The binary is copied out of the image without
# starting redis (docker create + cp + rm), so this works before the
# workload's own preflight. The temporary container is always removed.
ebpf_preflight_probes() {
  local tmp cname=bench-redis-symcheck line
  command -v readelf >/dev/null 2>&1 || { pf_fail "readelf not found (apt install binutils)"; return 0; }
  tmp=$(mktemp -d)
  docker rm -f "$cname" >/dev/null 2>&1 || true        # a leftover from a killed earlier check
  if docker create --name "$cname" "$REDIS_IMAGE" >/dev/null 2>&1 \
     && docker cp "$cname:$REDIS_SERVER_BIN_IN_IMAGE" "$tmp/redis-server" >/dev/null 2>&1; then
    line=$(readelf -sW "$tmp/redis-server" 2>/dev/null \
           | awk -v s="$REDIS_UPROBE_SYMBOL" '$4=="FUNC" && $8==s {print $2 " size " $3; exit}')
    if [[ -n $line ]]; then
      pf_ok "uprobe target $REDIS_UPROBE_SYMBOL: FUNC at 0x$line in $REDIS_IMAGE"
    else
      pf_fail "no FUNC symbol '$REDIS_UPROBE_SYMBOL' in $REDIS_IMAGE:$REDIS_SERVER_BIN_IN_IMAGE (stripped or renamed): use the fallback in redis_probes.c (processCommand, then tcp kprobes), as a labelled deviation"
    fi
  else
    pf_fail "cannot extract $REDIS_SERVER_BIN_IN_IMAGE from image $REDIS_IMAGE (docker create/cp failed)"
  fi
  docker rm -f "$cname" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}

# The bundle's target_pids holds the redis-server PID (written by wl_start).
# The binary is reached through /proc/PID/root because redis runs in a container.
ebpf_narrow_filter() {
  local pid bin
  pid=$(head -1 "$1/target_pids" 2>/dev/null | tr -d '[:space:]')
  [[ -n $pid ]] || die "no redis-server PID in $1/target_pids for narrow scope"
  bin="/proc/$pid/root$REDIS_SERVER_BIN_IN_IMAGE"
  [[ -e $bin ]] || die "redis-server binary $bin does not exist (container gone?)"
  EBPF_NARROW_ARGS=(--pids "$pid" --uprobe "$bin:$REDIS_UPROBE_SYMBOL:on_call")
}

source "$LAPTOP_ROOT/common/mech/ebpf.sh"
