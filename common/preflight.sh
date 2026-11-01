# preflight.sh — refuse-to-start checks. Sourced; call preflight_common, then
# each plugin's wl_preflight / mech_preflight. Every failure is collected and
# reported together, then the run aborts.

PF_FAILS=()
pf_fail() { PF_FAILS+=("$*"); log "  [FAIL] $*"; }
pf_ok()   { log "  [ok]   $*"; }

preflight_common() {
  stage "preflight"
  log "preflight"
  need_root
  local ac=0 ps t free
  for ps in /sys/class/power_supply/*; do
    [[ "$(cat "$ps/type" 2>/dev/null)" == Mains ]] && ac=$(cat "$ps/online")
  done
  [[ $ac == 1 ]] && pf_ok "on AC power" || pf_fail "not on AC power"

  t=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo none)
  [[ $t == performance ]] && pf_ok "platform profile performance" \
    || pf_fail "platform profile is '$t' (echo performance > /sys/firmware/acpi/platform_profile)"

  systemctl is-active --quiet tlp 2>/dev/null && pf_fail "TLP active (systemctl stop tlp)" || pf_ok "TLP not active"
  systemctl is-active --quiet unattended-upgrades 2>/dev/null \
    && pf_fail "unattended-upgrades active — a kernel bump mid-study breaks BTF and perf matching" \
    || pf_ok "unattended-upgrades not active"

  local noisy
  noisy="$(pgrep -l -x 'localsearch-ext|localsearch-3|tracker-miner-fs-3|tracker-extract-3|firefox|chrome|brave|Telegram|gnome-software|fwupd' 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ' || true)"
  [[ -z $noisy ]] && pf_ok "no noisy processes" || pf_fail "noisy processes running: $noisy"
  if pgrep -x 'gnome-shell|kwin_wayland|kwin_x11|Xorg|Xwayland|sway' >/dev/null 2>&1; then
    [[ ${ALLOW_GUI:-0} == 1 ]] && warn "graphical session running (ALLOW_GUI=1)" \
      || pf_fail "graphical session running — stop gdm and run from a TTY/ssh, or set ALLOW_GUI=1"
  else pf_ok "no graphical session"; fi

  t=$(pkg_temp_c)
  (( t <= TEMP_MAX_START_C )) && pf_ok "package ${t} °C" || pf_fail "package ${t} °C > ${TEMP_MAX_START_C} °C"

  free=$(df -Pm "$LAPTOP_ROOT" | awk 'NR==2{print $4}')
  (( free >= MIN_FREE_MB )) && pf_ok "${free} MB free" || pf_fail "${free} MB free < ${MIN_FREE_MB} MB"

  [[ "$(cat /proc/sys/net/core/bpf_jit_enable)" == 1 ]] && pf_ok "BPF JIT on" || pf_fail "bpf_jit_enable != 1"
  docker info >/dev/null 2>&1 && pf_ok "docker reachable" || pf_fail "docker daemon unreachable"
  local smt; smt=$(cat /sys/devices/system/cpu/smt/control)
  [[ $smt == on || $smt == off ]] || pf_fail "SMT control is '$smt' (cannot switch)"
}

preflight_port_free() {  # preflight_port_free PORT
  if ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; then pf_fail "port $1 in use"; else pf_ok "port $1 free"; fi
}

preflight_finish() {
  (( ${#PF_FAILS[@]} == 0 )) || die "preflight: ${#PF_FAILS[@]} check(s) failed"
  log "preflight passed"
}
