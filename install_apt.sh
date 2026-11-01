#!/usr/bin/env bash
# install_apt.sh — installs the Platform L dependencies that are certain to be
# in Ubuntu's own archive (main/universe). Run once, as root, before re-running
# probe_laptop.sh.
#
# Deliberately NOT here, because they are not in Ubuntu's archive (or only in a
# form the study cannot use) and need their own install step:
#   wrk2               build from github.com/giltene/wrk2 (apt's `wrk` has no -R)
#   memtier_benchmark  Redis's own apt repo or a source build
#   otelcol-contrib    upstream .deb, pinned to 0.161.0 to match Platform S
# Already present per the probe, so not reinstalled: perf (linux-tools-*),
# bpfcc-tools, python3-bpfcc, bpftrace, docker, sysstat, zstd, jq.
#
# Installs packages only. It does not upgrade the system, start or stop
# services, or touch any CPU/power setting.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0" >&2; exit 1; }

PKGS=(
  fio                 # the fio workload
  redis-tools         # redis-cli: readiness checks against the redis container
  nvme-cli            # NVMe device identity for the fio target
  smartmontools       # smartctl: drive model/firmware/health
  stress-ng           # optional noise/thermal sanity checks
  build-essential     # toolchain for building wrk2 and memtier from source
  git
  libssl-dev          # wrk2 build dependency
  zlib1g-dev          # wrk2 build dependency
  autoconf automake libtool pkg-config libevent-dev   # memtier source build
  "linux-tools-$(uname -r)"   # perf matching the running kernel (no-op if present)
  "linux-headers-$(uname -r)" # BCC compiles against these (no-op if present)
)

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${PKGS[@]}"

echo
echo "installed. versions:"
fio --version
redis-cli --version
nvme version
smartctl --version | head -1
stress-ng --version
echo
echo "still to install by hand: wrk2, memtier_benchmark, otelcol-contrib 0.161.0"
echo "then: docker pull nginx:1.24 redis:7 && sudo bash ./probe_laptop.sh"
