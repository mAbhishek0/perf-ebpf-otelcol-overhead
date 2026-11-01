#!/usr/bin/env bash
# install_build.sh — installs the Platform L dependencies that are NOT in
# Ubuntu's archive. Run after install_apt.sh (which brings the toolchain and
# -dev packages these builds need), as root:
#
#   sudo bash ./install_build.sh
#
#   wrk2               built from github.com/giltene/wrk2 -> /usr/local/bin/wrk2
#                      (the same source and install path Platform S used)
#   memtier_benchmark  built from github.com/RedisLabs/memtier_benchmark at its
#                      newest release tag, by the README's autoreconf/configure/make
#   otelcol-contrib    upstream release tarball, pinned to 0.161.0 to match
#                      Platform S, into /opt/otelcol (the tarball rather than
#                      the .deb, because the .deb installs and starts a systemd
#                      service — a background collector during every run)
#   docker images      nginx:1.24 (Platform S's image) and redis:7.4
#
# Each step is skipped if its tool is already installed at the right version,
# so the script is safe to re-run after a partial failure. Build trees go in a
# temp dir that is removed on exit.

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0" >&2; exit 1; }

OTELCOL_VERSION="0.161.0"
OTELCOL_DIR="/opt/otelcol"
NGINX_IMAGE="nginx:1.24"
REDIS_IMAGE="redis:7.4"

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
log() { printf '\n=== %s\n' "$*"; }

# Ubuntu 26.04 ships GCC 15, which defaults to C23 and (since GCC 14) turns
# implicit declarations and int/pointer mismatches into errors. Older C such as
# wrk2's bundled LuaJIT may trip on that. A plain build is tried first; only if
# it fails is it retried in gnu11 with those errors downgraded to warnings.
LEGACY_CC="gcc -std=gnu11 -fpermissive"

# ---------- wrk2 ----------
# wrk2 has no --version, and prints its usage with exit status 1. So the usage
# is captured into a variable before grepping: piping it straight into grep
# under `set -o pipefail` fails on that exit 1 even when the text matches.
has_rate_flag() { local u; u="$("$1" 2>&1 || true)"; [[ "$u" == *"-R, --rate"* ]]; }

# Help text is not enough: on new binutils, LuaJIT 2.0's `luajit -b` emits an
# ELF bytecode.o that ld calls corrupt ("string table [3] is corrupt") yet still
# links, and the bad object only shows at run time, when wrk's Lua script loads.
# So the binary has to drive a real request against a throwaway local server.
WRK2_TEST_PORT=18089
wrk2_works() {  # wrk2_works BINARY
  local srv out
  python3 -m http.server "$WRK2_TEST_PORT" --bind 127.0.0.1 --directory "$BUILD" >/dev/null 2>&1 &
  srv=$!
  sleep 1
  out="$("$1" -t1 -c1 -d2s -R10 "http://127.0.0.1:$WRK2_TEST_PORT/" 2>&1 || true)"
  kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null || true
  [[ "$out" == *"Requests/sec"* ]] || { echo "$out" | tail -5; return 1; }
}

if command -v wrk2 >/dev/null 2>&1 && has_rate_flag wrk2 && wrk2_works wrk2; then
  log "wrk2 already installed and working: $(command -v wrk2)"
else
  log "building wrk2"
  W="$BUILD/wrk2"
  git clone --depth 1 https://github.com/giltene/wrk2.git "$W"
  echo "wrk2 commit: $(git -C "$W" rev-parse HEAD)"
  if ! make -C "$W" -j"$(nproc)"; then
    log "plain build failed; retrying with CC='$LEGACY_CC'"
    make -C "$W" clean || true
    make -C "$W" -j"$(nproc)" CC="$LEGACY_CC"
  fi
  if ! wrk2_works "$W/wrk"; then
    # Fallback for the bad-ELF case: have the bundled luajit write the
    # bytecode as C source instead, compile that with the system compiler, and
    # relink. Same script, same exported luaJIT_BC_wrk symbol; only the object
    # file is produced by gcc rather than by LuaJIT's ELF writer.
    log "wrk2 built but does not run; regenerating bytecode.o via C source"
    (cd "$W/deps/luajit/src" && ./luajit -b "$W/src/wrk.lua" "$W/obj/bytecode.c")
    gcc -c "$W/obj/bytecode.c" -o "$W/obj/bytecode.o"
    rm -f "$W/wrk"
    make -C "$W"
    wrk2_works "$W/wrk" || { echo "wrk2 still fails its run test" >&2; exit 1; }
  fi
  install -m 0755 "$W/wrk" /usr/local/bin/wrk2
fi
has_rate_flag wrk2 || { echo "installed wrk2 has no -R option" >&2; exit 1; }
echo "wrk2 OK ($(command -v wrk2)): constant-rate test request succeeded"

# ---------- memtier_benchmark ----------
if command -v memtier_benchmark >/dev/null 2>&1; then
  log "memtier_benchmark already installed: $(memtier_benchmark --version 2>&1 | head -1)"
else
  log "building memtier_benchmark"
  # Newest release tag (x.y.z), so the build is a named version, not whatever
  # is on master today.
  TAG="$(git ls-remote --tags --refs https://github.com/RedisLabs/memtier_benchmark.git \
        | sed 's|.*refs/tags/||' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
  [[ -n "$TAG" ]] || { echo "could not find a memtier release tag" >&2; exit 1; }
  echo "memtier tag: $TAG"
  git clone --depth 1 --branch "$TAG" https://github.com/RedisLabs/memtier_benchmark.git "$BUILD/memtier"
  (
    cd "$BUILD/memtier"
    autoreconf -ivf
    ./configure
    if ! make -j"$(nproc)"; then
      echo "plain build failed; retrying with CC='$LEGACY_CC'"
      make clean || true
      ./configure CC="$LEGACY_CC"
      make -j"$(nproc)"
    fi
    make install
  )
fi
memtier_benchmark --version 2>&1 | head -1

# ---------- otelcol-contrib ----------
OTELCOL_BIN="$OTELCOL_DIR/otelcol-contrib"
if [[ -x "$OTELCOL_BIN" ]] && [[ "$("$OTELCOL_BIN" --version 2>&1 || true)" == *"$OTELCOL_VERSION"* ]]; then
  log "otelcol-contrib $OTELCOL_VERSION already at $OTELCOL_BIN"
else
  log "installing otelcol-contrib $OTELCOL_VERSION into $OTELCOL_DIR"
  BASE="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}"
  TGZ="otelcol-contrib_${OTELCOL_VERSION}_linux_amd64.tar.gz"
  curl -fsSL --retry 3 -o "$BUILD/$TGZ" "$BASE/$TGZ"
  # Verify against the release's per-file checksum. Releases ship no combined
  # checksums file; each artifact has its own "<artifact>.sha256" (signed via
  # a matching .sha256.sigstore.json). Its first field is the hex digest. A
  # missing .sha256 is reported; a mismatch aborts.
  GOT="$(sha256sum "$BUILD/$TGZ" | cut -d' ' -f1)"
  echo "tarball sha256: $GOT"
  if curl -fsSL --retry 3 -o "$BUILD/$TGZ.sha256" "$BASE/$TGZ.sha256"; then
    WANT="$(grep -oE '[0-9a-f]{64}' "$BUILD/$TGZ.sha256" | head -1)"
    [[ "$GOT" == "$WANT" ]] || { echo "sha256 MISMATCH: got $GOT, release says $WANT" >&2; exit 1; }
    echo "sha256 matches $BASE/$TGZ.sha256"
  else
    echo "WARNING: $BASE/$TGZ.sha256 not found; tarball not verified"
  fi
  tar -xzf "$BUILD/$TGZ" -C "$BUILD" otelcol-contrib
  install -d "$OTELCOL_DIR"
  install -m 0755 "$BUILD/otelcol-contrib" "$OTELCOL_BIN"
fi
"$OTELCOL_BIN" --version

# ---------- docker images ----------
log "pulling docker images"
docker pull "$NGINX_IMAGE"
docker pull "$REDIS_IMAGE"
docker image inspect --format '{{.RepoTags}} {{.Id}}' "$NGINX_IMAGE" "$REDIS_IMAGE"

log "done. re-run: sudo bash ./probe_laptop.sh"
