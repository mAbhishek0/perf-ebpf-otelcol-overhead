#!/usr/bin/env bash
# test_ebpf.sh — logic tests for the redis x eBPF pair; no root, no docker, no
# bcc, no hardware:  bash redis-memtier/ebpf/tests/test_ebpf.sh
# (common/tests/run_tests.sh runs it in its own process, because sourcing this
# pair's mech.sh defines mech_* that would replace nginx's in that shell.)
# Docker and readelf are PATH stubs. Covers: the wide region of redis_probes.c
# is byte-identical to nginx's and fio's (plan R13), the symbol preflight, the
# narrow filter arguments, and bcc_tracer.py --uprobe parsing.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAPTOP_ROOT="$(cd "$HERE/../../.." && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
source "$LAPTOP_ROOT/common/preflight.sh"
LOG_TAG=test
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
NPASS=0 NFAIL=0
ok()   { NPASS=$((NPASS+1)); }
bad()  { NFAIL=$((NFAIL+1)); printf 'FAIL: %s\n' "$*"; }
t_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1: expected '$2' got '$3'"; fi; }
t_die() { local d=$1; shift; if ( "$@" ) >/dev/null 2>&1; then bad "$d: expected failure"; else ok; fi; }

PY=""
for c in python3 python; do "$c" -c "import sys" >/dev/null 2>&1 && { PY=$c; break; }; done

# --- the shared parts of the probe file are byte-identical (R13) ---
rp="$LAPTOP_ROOT/redis-memtier/ebpf/scripts/redis_probes.c"
np="$LAPTOP_ROOT/nginx-wrk2/ebpf/scripts/nginx_probes.c"
fp="$LAPTOP_ROOT/fio/ebpf/scripts/fio_probes.c"
wide() { sed -n '/^#ifdef SCOPE_WIDE/,/^#endif \/\* SCOPE_WIDE \*\//p' "$1"; }
core() { sed -n '/^struct event_t {/,/^#ifdef SCOPE_NARROW/p' "$1"; }
w=$(wide "$rp")
[[ -n $w ]] && ok || bad "no SCOPE_WIDE region found in redis_probes.c"
t_eq "wide region = nginx's" "$(wide "$np")" "$w"
t_eq "wide region = fio's" "$(wide "$fp")" "$w"
t_eq "event/emit core = nginx's" "$(core "$np")" "$(core "$rp")"
grep -q 'int on_call(struct pt_regs' "$rp" && ok || bad "no on_call uprobe handler"
grep -q 'BPF_HASH(target_pids' "$rp" && ok || bad "no target_pids map (bcc_tracer --pids fills it)"
grep -q 'define KIND_REDIS_CALL' "$rp" && ok || bad "no KIND_REDIS_CALL"

# --- preflight, with stubbed docker and readelf ---
STUB="$T/bin"; mkdir -p "$STUB"
cat > "$STUB/docker" <<'SH'
#!/usr/bin/env bash
echo "docker $*" >> "$DOCKER_LOG"
if [[ $1 == cp ]]; then echo ELF > "$3"; fi
exit 0
SH
cat > "$STUB/readelf" <<'SH'
#!/usr/bin/env bash
cat "$READELF_OUT"
SH
chmod +x "$STUB/docker" "$STUB/readelf"
export DOCKER_LOG="$T/docker.log" READELF_OUT="$T/readelf.out"
source "$LAPTOP_ROOT/redis-memtier/ebpf/scripts/mech.sh"
t_eq "symbol name constant" call "$REDIS_UPROBE_SYMBOL"
t_eq "binary path constant" /usr/local/bin/redis-server "$REDIS_SERVER_BIN_IN_IMAGE"
printf '%s\n' "Symbol table '.symtab' contains 3 entries:" \
  "   Num:    Value          Size Type    Bind   Vis      Ndx Name" \
  "    41: 0000000000123456   812 FUNC    GLOBAL DEFAULT   14 call" \
  "    42: 0000000000123999    20 FUNC    GLOBAL DEFAULT   14 callFoo" > "$READELF_OUT"
PF_FAILS=(); : > "$DOCKER_LOG"; PATH="$STUB:$PATH" ebpf_preflight_probes > "$T/pf.out" 2>&1
t_eq "symbol present: no failure" 0 "${#PF_FAILS[@]}"
grep -q '^docker rm' "$DOCKER_LOG" && ok || bad "docker rm not called (symbol present)"
grep -q 'docker create --name bench-redis-symcheck redis:7.4' "$DOCKER_LOG" && ok || bad "docker create not as specified"
grep -q 'docker cp bench-redis-symcheck:/usr/local/bin/redis-server ' "$DOCKER_LOG" && ok || bad "docker cp not as specified"
grep -q '0x0000000000123456 size 812' "$T/pf.out" && ok || bad "ok line lacks address and size"
printf '%s\n' "    42: 0000000000123999    20 FUNC    GLOBAL DEFAULT   14 callFoo" \
  "    43: 0000000000124000    20 OBJECT  GLOBAL DEFAULT   14 call" > "$READELF_OUT"
PF_FAILS=(); : > "$DOCKER_LOG"; PATH="$STUB:$PATH" ebpf_preflight_probes >/dev/null 2>&1
t_eq "symbol absent (callFoo; non-FUNC call): fails" 1 "${#PF_FAILS[@]}"
[[ ${PF_FAILS[0]:-} == *processCommand* ]] && ok || bad "failure does not name the fallback"
grep -q '^docker rm' "$DOCKER_LOG" && ok || bad "docker rm not called (symbol absent)"
# docker cp failing must also fail, and still remove the container
cat > "$STUB/docker" <<'SH'
#!/usr/bin/env bash
echo "docker $*" >> "$DOCKER_LOG"
[[ $1 == cp ]] && exit 1
exit 0
SH
PF_FAILS=(); : > "$DOCKER_LOG"; PATH="$STUB:$PATH" ebpf_preflight_probes >/dev/null 2>&1
t_eq "docker cp fails: fails" 1 "${#PF_FAILS[@]}"
grep -q '^docker rm' "$DOCKER_LOG" && ok || bad "docker rm not called after cp failure"
# readelf missing: a PATH holding only coreutils-free stubs, so command -v finds none
NOREAD="$T/noreadelf"; mkdir -p "$NOREAD"
for t in docker mktemp rm awk; do ln -s "$(command -v $t)" "$NOREAD/$t"; done
PF_FAILS=(); PATH="$NOREAD" ebpf_preflight_probes >/dev/null 2>&1
t_eq "readelf missing: fails" 1 "${#PF_FAILS[@]}"
[[ ${PF_FAILS[0]:-} == *readelf* ]] && ok || bad "missing readelf not named"

# --- narrow filter ---
b="$T/bundle"; mkdir -p "$b"
echo 4242 > "$b/target_pids"
t_die "binary path missing dies" ebpf_narrow_filter "$b"     # /proc/4242 does not exist here
# the same function against a fake /proc root, by rewriting the one path prefix
fake="$T/proc"; mkdir -p "$fake/4242/root/usr/local/bin"; : > "$fake/4242/root/usr/local/bin/redis-server"
sed "s|/proc/\$pid/root|$fake/\$pid/root|" "$LAPTOP_ROOT/redis-memtier/ebpf/scripts/mech.sh" > "$T/mech_fake.sh"
( source "$T/mech_fake.sh"; ebpf_narrow_filter "$b"; printf '%s\n' "${EBPF_NARROW_ARGS[@]}" ) > "$T/nf.out" 2>&1
t_eq "narrow args: --pids" "--pids" "$(sed -n 1p "$T/nf.out")"
t_eq "narrow args: pid" 4242 "$(sed -n 2p "$T/nf.out")"
t_eq "narrow args: --uprobe" "--uprobe" "$(sed -n 3p "$T/nf.out")"
t_eq "narrow args: spec" "$fake/4242/root/usr/local/bin/redis-server:call:on_call" "$(sed -n 4p "$T/nf.out")"
grep -q 'bin="/proc/\$pid/root\$REDIS_SERVER_BIN_IN_IMAGE"' "$LAPTOP_ROOT/redis-memtier/ebpf/scripts/mech.sh" && ok || bad "real mech.sh does not use /proc/PID/root"
: > "$b/target_pids"
t_die "empty PID dies" ebpf_narrow_filter "$b"

# --- bcc_tracer.py --uprobe parsing (bcc is imported only inside run(), so no bcc needed) ---
if [[ -n $PY ]]; then
  "$PY" -I "$HERE/test_uprobe_args.py" >/dev/null 2>&1 && ok || bad "test_uprobe_args.py (run it alone for details)"
fi
printf 'redis ebpf tests: %s passed, %s failed\n' "$NPASS" "$NFAIL"
(( NFAIL == 0 ))
