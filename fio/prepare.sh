#!/usr/bin/env bash
# prepare.sh — write fio's data file once (PLAN.md decision 3.3). Entry point.
#   sudo bash fio/prepare.sh           # refuses if the file exists
#   sudo bash fio/prepare.sh --force   # rewrite it; a new file needs new results dirs
#
# Sequential 1 MiB O_DIRECT writes of FIO_FILE_BYTES to FIO_FILE, then fsync.
# Matrix runs only READ this file, so the QLC drive's SLC write cache never
# fills during a measurement. After this, leave the laptop idle for at least
# 30 minutes before the pilot, so the drive can move the data out of its SLC
# cache: reads during that folding would measure the drive's housekeeping.
# Records FIO_FILE.env (time, size, fio version, device), which wl_preflight
# and provenance read.
set -euo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
LOG_TAG=fio-prepare
need_root
source "$LAPTOP_ROOT/fio/fio.env"

FORCE=0
[[ ${1:-} == --force ]] && FORCE=1
[[ -e $FIO_FILE && $FORCE == 0 ]] && die "$FIO_FILE exists — --force rewrites it (and then fio needs new results dirs)"
mkdir -p "$FIO_DATA_DIR"
need=$(( FIO_FILE_BYTES / 1024 / 1024 + MIN_FREE_MB ))
free=$(df -BM --output=avail "$FIO_DATA_DIR" | tail -n 1 | tr -dc 0-9)
(( free >= need )) || die "$FIO_DATA_DIR has ${free} MB free, need ${need} MB"
rm -f "$FIO_FILE" "$FIO_FILE.env"

log "writing $FIO_FILE_BYTES bytes to $FIO_FILE (sequential, O_DIRECT)"
fio --name=prepare --filename="$FIO_FILE" --rw=write --bs=1M --direct=1 --ioengine="$FIO_ENGINE" \
    --iodepth=8 --size="$FIO_FILE_BYTES" --end_fsync=1 --output="$FIO_DATA_DIR/prepare.out" \
  || die "fio write failed (see $FIO_DATA_DIR/prepare.out)"
[[ "$(stat -c %s "$FIO_FILE")" == "$FIO_FILE_BYTES" ]] || die "$FIO_FILE is not $FIO_FILE_BYTES bytes"

src=$(findmnt -no SOURCE --target "$FIO_DIR")
: > "$FIO_FILE.env.partial"
kv_put "$FIO_FILE.env.partial" PREPARED_AT "$(date -Is)"
kv_put "$FIO_FILE.env.partial" FILE_BYTES "$FIO_FILE_BYTES"
kv_put "$FIO_FILE.env.partial" FIO_VERSION "$(fio --version)"
kv_put "$FIO_FILE.env.partial" SOURCE "$src"
kv_put "$FIO_FILE.env.partial" KERNEL "$(uname -r)"
mv "$FIO_FILE.env.partial" "$FIO_FILE.env"
log "done. Leave the laptop idle for at least 30 minutes before: sudo bash pilot.sh fio"
