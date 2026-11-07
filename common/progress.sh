# progress.sh — progress display for long runs. Sourced; requires lib.sh.
#
# Without it, a run is a black screen for hours (quiesce stops gdm) and the
# only way to see progress is to log in on another VT and read the log.
#
#   progress_init N     after quiesce: take over a text console (STATUS_VT),
#                       disable its blanking, switch to it once
#   progress_cell CELL  at the start of each cell (bracket.sh)
#   progress_run ROLE IDX TRY / progress_run_done
#                       around every run_one call, i.e. only BETWEEN runs —
#                       nothing here runs during ramp or steady state
#   progress_cell_end CELL TRY VERDICT TEXT   after each bracket verdict
#   progress_finish RC  on exit: FINISHED/ABORTED screen held STATUS_HOLD_S,
#                       then the console and its blanking are restored
#
# Every redraw writes logs/status.txt (overwritten, atomic) and, if the console
# was taken, repaints it in place: one history line per finished cell try plus
# a live line. The screen stays lit for the whole run, so backlight heat is the
# same in A and B runs. Optional phone push through ntfy.sh at cell boundaries
# and finish only (network traffic during a run is noise): put
# NOTIFY_NTFY_TOPIC=<random topic> in notify.env (gitignored — the topic name
# is the only secret) and subscribe to that topic in the ntfy app.

STATUS_VT=${STATUS_VT:-8}             # outside logind's autovt range (tty1-6), so no getty draws over it
STATUS_HOLD_S=${STATUS_HOLD_S:-30}    # final screen shown this long before gdm restarts
STATUS_RUN_S_GUESS=150                # ETA before the first run has been timed (~2.5 min/run)
STATUS_HIST_MAX=40
PROGRESS_FILE="${LAPTOP_ROOT}/logs/status.txt"
PROGRESS_CONSOLE_STATE="${STATE_DIR}/status_console.env"

P_ON=0 P_N=0 P_K=0 P_T0=0 P_TTY="" P_CELL="" P_TRY=1 P_ROLE="" P_IDX=0
P_RUNS=0 P_RUN_S=0 P_RS=0 P_LAST="none yet" P_HIST=() P_OK=0
P_PER_TRY=$(( ${WARMUP_REPS:-1} + ${MEASURED_REPS:-6} + 2 ))

# --- pure helpers (unit-tested) ---
fmt_dur() {  # seconds -> 1h02m / 4m05s
  local s=${1%.*}; (( s < 0 )) && s=0
  if (( s >= 3600 )); then printf '%dh%02dm' $((s/3600)) $((s%3600/60)); else printf '%dm%02ds' $((s/60)) $((s%60)); fi
}
# runs left: the rest of the current try (from run IDX, 0-based) + one try per later cell
progress_runs_left() {  # N K PER_TRY IDX
  local n=$1 k=$2 per=$3 idx=$4 cur
  cur=$(( per - idx )); (( cur < 0 )) && cur=0
  (( k == 0 )) && cur=0
  echo $(( cur + (n - k) * per ))
}

_p_notify() {
  local topic="${NOTIFY_NTFY_TOPIC:-}"
  [[ -z $topic && -f $LAPTOP_ROOT/notify.env ]] && topic=$(kv_get "$LAPTOP_ROOT/notify.env" NOTIFY_NTFY_TOPIC 2>/dev/null || true)
  [[ -n $topic ]] && command -v curl >/dev/null || return 0
  timeout 10 curl -s -o /dev/null -m 8 -H "Title: bench ${BENCH_UNIT:-run}" -d "$*" "https://ntfy.sh/$topic" \
    || warn "ntfy push failed (ignored)"
  return 0
}

_p_draw() {  # $1 = live line
  (( P_ON )) || return 0
  local now el avg left eta txt
  now=$(date +%s); el=$(( now - P_T0 ))
  avg=$STATUS_RUN_S_GUESS; (( P_RUNS > 0 )) && avg=$(( P_RUN_S / P_RUNS ))
  left=$(progress_runs_left "$P_N" "$P_K" "$P_PER_TRY" "$P_IDX")
  eta=$(( left * avg ))
  txt="bench ${BENCH_UNIT:-run} — started $(date -d "@$P_T0" +%H:%M) — log ${BENCH_LOG:-?}"$'\n'
  txt+="$(printf '%s\n' "${P_HIST[@]: -$STATUS_HIST_MAX}")"$'\n'
  txt+=$'\n'"$1"$'\n'
  txt+="elapsed $(fmt_dur "$el")   avg run $(fmt_dur "$avg")   ETA $(date -d "@$(( now + eta ))" +%H:%M) (+$(fmt_dur "$eta"), $left runs, no retries assumed)"$'\n'
  txt+="last drift: $P_LAST"$'\n'
  mkdir -p "${PROGRESS_FILE%/*}"
  printf '%s' "$txt" > "$PROGRESS_FILE.partial" && mv -f "$PROGRESS_FILE.partial" "$PROGRESS_FILE"
  [[ -n $P_TTY ]] && { printf '\033[H\033[2J%s' "$txt" > "$P_TTY"; } 2>/dev/null
  return 0
}

progress_init() {  # N_CELLS
  P_ON=1 P_N=$1 P_T0=$(date +%s)
  local tty="/dev/tty$STATUS_VT" prev cb
  if [[ ${STATUS_CONSOLE:-1} == 1 && ${QUIESCED:-0} == 1 ]] && command -v chvt >/dev/null && [[ -e $tty ]]; then
    prev=$(fgconsole 2>/dev/null || echo 1)
    cb=$(cat /sys/module/kernel/parameters/consoleblank 2>/dev/null || echo 0)
    if [[ ! -f $PROGRESS_CONSOLE_STATE ]]; then   # never overwrite: it is the restore record
      mkdir -p "$STATE_DIR"
      : > "$PROGRESS_CONSOLE_STATE.partial"
      kv_put "$PROGRESS_CONSOLE_STATE.partial" PREV_VT "$prev"
      kv_put "$PROGRESS_CONSOLE_STATE.partial" CONSOLEBLANK_S "$cb"
      kv_put "$PROGRESS_CONSOLE_STATE.partial" VT "$STATUS_VT"
      mv "$PROGRESS_CONSOLE_STATE.partial" "$PROGRESS_CONSOLE_STATE"
    fi
    setterm --blank 0 --powerdown 0 --cursor off > "$tty" < "$tty" 2>/dev/null || warn "setterm on tty$STATUS_VT failed — console may blank"
    if chvt "$STATUS_VT" 2>/dev/null; then
      P_TTY=$tty; log "progress shown on tty$STATUS_VT (blanking off)"
    else
      warn "could not take over tty$STATUS_VT — progress only in $PROGRESS_FILE"
    fi
  fi
  _p_draw "starting: $P_N cells, $P_PER_TRY runs per try"
}

progress_cell() { (( P_ON )) || return 0; P_K=$(( P_K + 1 )) P_CELL=$1 P_TRY=1 P_IDX=0; }

progress_run() {  # ROLE IDX(0-based within the try) TRY
  (( P_ON )) || return 0
  P_ROLE=$1 P_IDX=$2 P_TRY=$3 P_RS=$(date +%s)
  _p_draw "cell $P_K/$P_N $P_CELL   try $P_TRY/${MAX_TRIES:-3}   run $P_ROLE ($(( P_IDX + 1 ))/$P_PER_TRY)"
}
progress_run_done() {
  (( P_ON && P_RS > 0 )) || return 0
  P_RUNS=$(( P_RUNS + 1 )) P_RUN_S=$(( P_RUN_S + $(date +%s) - P_RS )) P_RS=0 P_IDX=$(( P_IDX + 1 ))
}

progress_cell_end() {  # CELL TRY VERDICT TEXT
  (( P_ON )) || return 0
  local line
  line=$(printf '[%2d/%d] %-26s try %d  %-5s %s  %s' "$P_K" "$P_N" "$1" "$2" "$3" "$4" "$(date +%H:%M)")
  P_HIST+=("$line"); P_LAST="$1 try $2: $3 ($4)"
  [[ $3 == ok ]] && P_OK=$(( P_OK + 1 ))
  [[ $3 == ok ]] && P_IDX=$P_PER_TRY || P_IDX=0   # drift: the next try starts from run 0
  _p_draw "cell $P_K/$P_N done"
  _p_notify "$line"
}

progress_finish() {  # RC
  local rc=$1 msg reason=""
  if (( rc == 0 )); then
    msg="FINISHED $P_OK/$P_N cells ok in $(fmt_dur $(( $(date +%s) - P_T0 )))"
  else
    [[ -n ${CRASH_ERRFILE:-} && -f $CRASH_ERRFILE ]] && reason=$(grep ' die ' "$CRASH_ERRFILE" | tail -1 | cut -d' ' -f3-)
    msg="ABORTED: ${reason:-exit status $rc} — $P_OK/$P_N cells ok"
  fi
  if (( P_ON )); then
    P_IDX=$P_PER_TRY; _p_draw "$msg"$'\n'"log: ${BENCH_LOG:-?}"
  else
    mkdir -p "${PROGRESS_FILE%/*}"; printf '%s\n' "$msg" > "$PROGRESS_FILE" 2>/dev/null
  fi
  _p_notify "$msg"
  if [[ -n $P_TTY ]]; then sleep "$STATUS_HOLD_S"; fi
  progress_console_restore
  P_ON=0
  return 0
}

# Also called by revert.sh after a crash.
progress_console_restore() {
  [[ -f $PROGRESS_CONSOLE_STATE ]] || return 0
  local vt prev cb
  vt=$(kv_get "$PROGRESS_CONSOLE_STATE" VT); prev=$(kv_get "$PROGRESS_CONSOLE_STATE" PREV_VT)
  cb=$(kv_get "$PROGRESS_CONSOLE_STATE" CONSOLEBLANK_S)
  setterm --blank $(( ${cb:-0} / 60 )) --cursor on > "/dev/tty$vt" < "/dev/tty$vt" 2>/dev/null || warn "could not restore blanking on tty$vt"
  chvt "${prev:-1}" 2>/dev/null || true
  mv "$PROGRESS_CONSOLE_STATE" "$STATE_DIR/status_console.restored.$(date +%s).env"
  P_TTY=""
}
