# Provenance — nginx × eBPF matrix, Platform L (2026-11-07)

Written 2026-11-07, after the runs. Runs from this date onward write
`provenance/<timestamp>_<mech>.env` automatically (harness commit, tool
versions); this matrix predates that, so its provenance is reconstructed here
from the evidence listed. Nothing below is assumed without a source.

| Item | Value | Evidence |
|---|---|---|
| Rows | 64 (8 cells × A1, B1–B6, A2), schema 2.1.0 | `nginx_ebpf.csv`, `schema.json` |
| Run | 18:20–22:11, one invocation, level order `2 4 3 1`; narrow E3 and wide E1 on try 2 (CPU drift), the rest on try 1 | `logs/bench-nginx_20261107-182010.log`; README timeline 21 |
| Harness code | `4755703` (inferred: last code commit before 18:20; `bfd1c6b`, `1ff9db3` are results/docs only) | `git log` timestamps |
| Kernel | 7.0.0-43-generic | `KERNEL` in every `raw/*/run_meta.env` |
| BCC | 0.35.0 (distro python bindings, `/usr/bin/python3`) | preflight `[ok] BCC python bindings (0.35.0)` in the log; `logs/ebpf-check_20261107-181204.txt` header |
| nginx image | `nginx:1.24`, id pinned in `common/config.env` (`NGINX_IMAGE_ID`) | preflight `[ok] nginx:1.24 id matches` |
| wrk2 | patched `ae.c` overdue-timer fix (`install_build.sh` at `fca0a1d`) | install stamp; no stalls in any run. Preflight did not check the stamp, so this is indirect |
| Tracer source | `nginx-wrk2/ebpf/scripts/` (`bcc_tracer.py`, `nginx_probes.c`, `mech.sh`) at the harness commit | git |
| Constants | perf buffer pages, CPU layout, ladder, rep counts | `schema.json` (frozen, byte-checked by every `collect`) |

Not recorded and not recoverable: the binary checksum of wrk2 and whether the
laptop checkout had uncommitted edits at run time. Not measured by design: the
eBPF programs' in-kernel CPU (`bpf_stats` off), as on Platform S.
