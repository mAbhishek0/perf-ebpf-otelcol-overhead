# quiesce.sh — close noisy apps and stop noisy services before a workload;
# restart only the services that were running (desktop included) afterwards.
# Sourced. Apps (browsers, Telegram) are closed, never restarted.
#
# Which services were active is saved to state/quiesced.env before anything is
# stopped, so the restore — from the EXIT trap, or from revert.sh after a
# crash — starts exactly those and nothing else. gdm is started last.
# Opt out with QUIESCE=0 (then preflight refuses while noise is present).

# Sockets/paths listed so they cannot re-activate a stopped service mid-run.
QUIESCE_SERVICES="tlp fwupd fwupd-refresh.timer cups.socket cups.path cups cups-browsed snapd.socket snapd ModemManager bluetooth nvidia-powerd power-profiles-daemon smartmontools gdm"
QUIESCE_APPS="firefox chrome brave Telegram gnome-software localsearch-ext localsearch-3 tracker-miner-fs-3 tracker-extract-3"
QFILE="${STATE_DIR}/quiesced.env"

quiesce_preview() {  # what would be closed/stopped; run in the launcher, before detaching
  local s a running="" apps=""
  for s in $QUIESCE_SERVICES; do systemctl is-active --quiet "$s" 2>/dev/null && running+="$s "; done
  apps=$(pgrep -l -x "${QUIESCE_APPS// /|}" 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ' || true)
  log "will stop services: ${running:-none}"
  log "will close apps (NOT restarted; unsaved work is lost): ${apps:-none}"
}

quiesce() {
  stage "quiesce"
  mkdir -p "$STATE_DIR"
  local s active=""
  for s in $QUIESCE_SERVICES; do systemctl is-active --quiet "$s" 2>/dev/null && active+="$s "; done
  if [[ ! -f $QFILE ]]; then           # never overwrite: it is the restore list
    : > "$QFILE.partial"; kv_put "$QFILE.partial" SERVICES "$active"; mv "$QFILE.partial" "$QFILE"
  fi
  for s in $active; do systemctl stop "$s" 2>/dev/null || warn "could not stop $s"; done
  local pat="${QUIESCE_APPS// /|}"
  pkill -TERM -x "$pat" 2>/dev/null || true
  wait_for 15 apps-exit _no_apps "$pat" || { warn "apps ignored SIGTERM — killing"; pkill -KILL -x "$pat" 2>/dev/null || true; }
  wait_for 30 desktop-exit _no_apps 'gnome-shell|Xwayland|Xorg|kwin_wayland|kwin_x11|sway' \
    || warn "desktop processes still running 30 s after stopping gdm"
  log "quiesced: stopped [${active:-none}], apps closed"
}
_no_apps() { ! pgrep -x "$1" >/dev/null 2>&1; }

quiesce_restore() {
  stage "restore services"
  [[ -f $QFILE ]] || return 0
  local s list gdm=0
  list=$(kv_get "$QFILE" SERVICES)
  for s in $list; do
    [[ $s == gdm ]] && { gdm=1; continue; }
    systemctl start "$s" 2>/dev/null || warn "could not restart $s"
  done
  (( gdm )) && { systemctl start gdm || warn "could not restart gdm"; }
  mv "$QFILE" "$STATE_DIR/quiesced.restored.$(date +%s).env"
  log "restored services: ${list:-none}"
}

# Deeper quiet, for one diagnostic variant (diag_stall.sh "quiet"): stop every
# active timer and a list of background services, block all radios (no wifi
# IRQs, no network chatter) and freeze user.slice (sessions, the launcher's
# log follower). The harness and nginx run in BENCH_SLICE, so they are
# untouched. What was active is saved to state/quiet.env before anything is
# stopped, so quiet_off — or revert.sh after a crash — undoes exactly that.
QUIET_SERVICES="NetworkManager wpa_supplicant avahi-daemon cron anacron unattended-upgrades packagekit rsyslog systemd-timesyncd thermald whoopsie apport kerneloops colord udisks2 upower switcheroo-control accounts-daemon"
QUIETFILE="${STATE_DIR}/quiet.env"

quiet_on() {
  mkdir -p "$STATE_DIR"
  local s active="" timers rf
  for s in $QUIET_SERVICES; do systemctl is-active --quiet "$s" 2>/dev/null && active+="$s "; done
  timers=$(systemctl list-units --type=timer --state=active --plain --no-legend 2>/dev/null | awk '{printf "%s ", $1}')
  rf=$(rfkill -n -o ID,SOFT 2>/dev/null | awk '$2=="unblocked"{printf "%s ", $1}')
  if [[ ! -f $QUIETFILE ]]; then       # never overwrite: it is the restore list
    : > "$QUIETFILE.partial"
    kv_put "$QUIETFILE.partial" SERVICES "$active"
    kv_put "$QUIETFILE.partial" TIMERS "$timers"
    kv_put "$QUIETFILE.partial" RFKILL "$rf"
    mv "$QUIETFILE.partial" "$QUIETFILE"
  fi
  for s in $timers $active; do systemctl stop "$s" 2>/dev/null || warn "could not stop $s"; done
  [[ -n $rf ]] && { rfkill block all 2>/dev/null || warn "could not block radios"; }
  systemctl freeze user.slice 2>/dev/null || warn "could not freeze user.slice"
  log "quiet: stopped [${active:-none}], timers [${timers:-none}], radios [${rf:-none}] blocked, user.slice frozen"
}

quiet_off() {
  [[ -f $QUIETFILE ]] || return 0
  local s id
  systemctl thaw user.slice 2>/dev/null || true
  for id in $(kv_get "$QUIETFILE" RFKILL); do rfkill unblock "$id" 2>/dev/null || warn "could not unblock radio $id"; done
  for s in $(kv_get "$QUIETFILE" SERVICES) $(kv_get "$QUIETFILE" TIMERS); do
    systemctl start "$s" 2>/dev/null || warn "could not restart $s"
  done
  mv "$QUIETFILE" "$STATE_DIR/quiet.restored.$(date +%s).env"
  log "quiet: restored"
}
