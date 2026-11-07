# provenance.sh — record what produced a results directory. Sourced; requires lib.sh.
#
# provenance_write RESULTS_DIR MECH
#   Writes RESULTS_DIR/provenance/<timestamp>.env once per run_workload
#   invocation, before any cell runs (never inside a measured window): the
#   harness commit (and whether tracked scripts had local edits), kernel, and
#   the version of every tool a row depends on. schema.json freezes the
#   constants; this file pins the software. Anything not installed reads NA.
#   For a paper, every result must be traceable to the exact code and tools.

_prov_cmd() { local out; out=$("$@" 2>/dev/null | head -n 1) || true; echo "${out:-NA}"; }

provenance_write() {
  local rdir=$1 mech=$2 f git dirty
  mkdir -p "$rdir/provenance"
  f="$rdir/provenance/$(date +%Y%m%d-%H%M%S)_${mech}.env"
  git=(git -C "$LAPTOP_ROOT" -c safe.directory='*')
  dirty=$("${git[@]}" status --porcelain --untracked-files=no -- . ':!*/results/*' ':!logs/*' 2>/dev/null | wc -l | tr -d ' ')
  : > "$f.partial"
  kv_put "$f.partial" WRITTEN_AT "$(date -Is)"
  kv_put "$f.partial" MECHANISM "$mech"
  kv_put "$f.partial" HARNESS_COMMIT "$(_prov_cmd "${git[@]}" rev-parse HEAD)"
  kv_put "$f.partial" HARNESS_LOCAL_EDITS "${dirty:-NA}"
  kv_put "$f.partial" KERNEL "$(uname -r)"
  kv_put "$f.partial" OS "$(_prov_cmd awk -F= '$1=="PRETTY_NAME"{gsub(/"/,"",$2); print $2}' /etc/os-release)"
  kv_put "$f.partial" CPU_MODEL "$(_prov_cmd awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)"
  kv_put "$f.partial" BIOS_VERSION "$(_prov_cmd cat /sys/class/dmi/id/bios_version)"
  kv_put "$f.partial" PERF_VERSION "$(_prov_cmd perf --version)"
  kv_put "$f.partial" BCC_VERSION "$(_prov_cmd "${EBPF_PYTHON:-python3}" -c 'import bcc; print(bcc.__version__)')"
  kv_put "$f.partial" PYTHON_VERSION "$(_prov_cmd "${EBPF_PYTHON:-python3}" --version)"
  kv_put "$f.partial" OTELCOL_VERSION "$(_prov_cmd "${OTELCOL_BIN:-/opt/otelcol/otelcol-contrib}" --version)"
  kv_put "$f.partial" WRK2_SHA256 "$(_prov_cmd sha256sum "${WRK2_BIN:-/usr/local/bin/wrk2}")"
  kv_put "$f.partial" WRK2_AE_FIX "$([[ -e /usr/local/share/wrk2-ae-timeout-fix ]] && echo yes || echo no)"
  kv_put "$f.partial" DOCKER_VERSION "$(_prov_cmd docker version --format '{{.Server.Version}}')"
  kv_put "$f.partial" NGINX_IMAGE_ID "$(_prov_cmd docker image inspect --format '{{.Id}}' "${NGINX_IMAGE:-nginx:1.24}")"
  mv "$f.partial" "$f"
  log "provenance: $f"
}
