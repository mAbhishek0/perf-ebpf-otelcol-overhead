# Provenance — nginx × perf matrix, Platform L (2026-11-07)

Written 2026-11-07, after the runs. Runs from this date onward write
`provenance/<timestamp>_<mech>.env` automatically (harness commit, tool
versions); this matrix predates that, so its provenance is reconstructed here
from the evidence listed. Nothing below is assumed without a source.

| Item | Value | Evidence |
|---|---|---|
| Rows | 64 (8 cells × A1, B1–B6, A2), schema 2.1.0 | `nginx_perf.csv`, `schema.json` |
| Runs | re-run 1: 11:50–12:37 (cells narrow E2, wide E2); re-run 2: 13:37–15:56 (the other 6) | `logs/bench-nginx_20261107-115041.log`, `logs/bench-nginx_20261107-133700.log`; README timeline 17 |
| Harness code, re-run 1 | `13fc5c6` (inferred: last commit pushed before 11:50) | `git log` timestamps |
| Harness code, re-run 2 | `5dcad8c` (inferred: last code commit before 13:37; `b24e74d` is docs only) | `git log` timestamps |
| CSV restated | `restat.sh` at `0851bee`/`f89c5f6`: loss definition of schema 2.0.0, columns of 2.1.0; interrupt-split and power columns NA (not captured then) | README timeline 18–19 |
| Kernel | 7.0.0-43-generic | `KERNEL` in every `raw/*/run_meta.env` |
| perf | 7.0.14 | preflight `[ok] perf version 7.0.14` in both logs (preflight refuses any other version) |
| nginx image | `nginx:1.24`, id pinned in `common/config.env` (`NGINX_IMAGE_ID`) | preflight `[ok] nginx:1.24 id matches` in both logs |
| wrk2 | patched `ae.c` overdue-timer fix (`install_build.sh` at `fca0a1d`) | install stamp; diagnostic run 4 0/5 stalls; max ≤ 18.4 ms in all 64 runs. Preflight did not check the stamp, so this is indirect |
| Constants | sampling frequencies, buffer sizes, CPU layout, ladder, rep counts | `schema.json` (frozen, byte-checked by every `collect`) |

Not recorded and not recoverable: the binary checksum of wrk2 and whether the
laptop checkout had uncommitted edits at run time.
