# nginx × OpenTelemetry Collector (otelcol-contrib, scraper mode)

**Status: written 2026-11-07, never run on hardware.** Only `bash -n` and the logic tests
(`bash nginx-wrk2/collector/tests/test_mech.sh`, 63 checks) have run, in Git Bash.

Run on the laptop, from the repo root:

```bash
sudo bash nginx-wrk2/collector/scripts/check.sh   # ~5 min shakedown: narrow+wide at E1 and E4, no results written
sudo bash nginx-wrk2/collector/scripts/run.sh     # full matrix: 4 levels x 2 scopes, ~3 h
```

## What is collected

Ported from Platform S (`docs/drafts/nginx-perf-pipeline-server/sidecar/`, 88 runs there,
`MATRIX-RESULTS-nginx-collector-S.md`). The two YAML templates are S's with only the comments
shortened; their non-comment lines are byte-identical to S's (checked with `diff`).

| scope | receivers (pipeline) | scrapers | interval | per-workload? |
|---|---|---|---|---|
| narrow | `nginx` (stub_status `http://127.0.0.1:8080/status`) | 1 | 15 s | yes |
| wide | `nginx` + `hostmetrics` (cpu memory disk network load filesystem paging processes) | 1 + 8 = 9 | 1 s | no — hostmetrics is host-wide |

Both scopes: `batch` processor (`send_batch_size` 512), `debug` exporter (verbosity `basic`)
with `sending_queue` 512 items, self-telemetry at `level: detailed` on 127.0.0.1:18888
(pull reader). Constants in [collector.env](../scripts/collector.env), all S values.

otelcol-contrib **0.161.0** from `/opt/otelcol/otelcol-contrib` (install_build.sh: release
tarball, sha256-verified, not the .deb). It runs as a host process pinned to `TRACER_CPUS`
(8,10) from attach to detach, as perf and BCC do. `/status` is served in every run under every
mechanism (`workload.sh`), so the workload is identical; the scrapes add a few requests that
nginx serves inside its own cgroup (one-directional, small: 1/s wide, 1/15 s narrow).

## Identical to S

Receivers, scrapers, scope → interval mapping (15 s / 1 s), batch 512, debug exporter at
`basic`, sending queue 512, telemetry port 18888, `level: detailed`, the `readers: pull`
telemetry form 0.161.0 requires, otelcol version, attach timeout 30 s, shutdown SIGTERM then
SIGKILL after 15 s, counters read from otelcol's own Prometheus endpoint once before and once
after and differenced (an absent counter = 0, an absent gauge = not reported), receiver count
parsed from the pipeline's flow-style list, tracer CPU from `/proc/<otelcol pid>/stat`
utime+stime (otelcol's own PID, never a wrapper's), self-reported CPU kept only as a
cross-check, the `accepted > 0` ingest guard.

## Changed for this harness, and why

| S | here | why |
|---|---|---|
| wrapper `otel_tracer.sh` holds the window open for `--duration`, publishes otelcol's PID | no wrapper: `mech_attach` starts otelcol under `taskset`, `mech_detach` stops it | `run_one.sh` opens and closes the window; same shape as the perf/eBPF plugins. `pids.tracer` holds otelcol's PID directly, so S's sleeping-wrapper trap cannot happen. `/proc/<pid>/comm` is checked to be `otelcol-contrib` |
| counter window = `--duration` (= steady) | attach → detach (ramp end → after the window closes), measured, in `OTEL_WINDOW_S` | same convention as perf/eBPF event counts here; both telemetry reads stay outside the measured window. `OTEL_SCRAPES_EXPECTED` = ⌊window ÷ interval⌋ |
| co-located layout (generator on the aggregator cores) | dedicated 4+2+2 layout | laptop layout decision; gives the isolated collector arm S never ran |
| `KEY=value` stats file written by the wrapper | `otel_baseline.prom`, `otel_final.prom`, `otel_stop.env` in the bundle; `mech_stats` computes `mech.stats` (kv) | harness format; raw reads kept so stats can be recomputed |
| dropped = refused + send_failed; ratio "not applicable" | **schema 2.x loss**: `mech_lost` = receiver refused + receiver failed + exporter send_failed, `mech_events` = exporter sent, `mech_drop_rate` = lost ÷ (sent + lost) | one definition for every mechanism (lost ÷ (delivered + lost) over everything the mechanism runs). Receiver `failed` added: it is a lost outcome in the same population. Scraper errors are a different population (S: 140 scraped vs 245 accepted), so they are noted, never in the ratio |
| `accepted > 0` over all receivers | `accepted > 0` **for receiver `nginx`** (and for `hostmetrics` in wide) | in wide, hostmetrics alone keeps the total above 0 while a broken `/status` scrape zeroes nginx — S's 403 failure would pass S's guard in wide |
| 403 seen only in `otelcol.log` | error/warn lines in `otelcol.log` counted (`OTEL_LOG_ERRORS`, noted when > 0); `/status` must answer 200 before otelcol starts | LESSONS: grep `otelcol.log` every run |
| network: bridge + published port | `--network host` (workload.sh) | scrapes arrive from 127.0.0.1, no docker-proxy on the load path |
| — | attach refuses if 18888 is already bound or the rendered config has the wrong receiver/scraper count (1/0 narrow, 2/8 wide) | a leftover collector would be read instead; a template edit cannot silently change the scope |
| `mech_detach`-equivalent failures in the wrapper | `mech_detach` never dies; it records `OTEL_EXIT` (`ok`, `collector_died`, `final_scrape_failed`, `collector_killed`) and `mech_stats` fails the run unless `ok` | it also runs from the EXIT trap, where a `die` would skip the host revert |

## Columns

- `mech_events`: metric points the exporter sent (attach → detach). `mech_lost`: refused +
  receiver failed + send_failed. `mech_drop_rate`: lost ÷ (events + lost).
- `tracer_cpu_cores`: otelcol's own utime+stime from `/proc`, by the sampler, the same path as
  perf's and BCC's. Includes all of otelcol's Go threads; GOMAXPROCS follows the 2-CPU
  affinity mask. `OTEL_SELF_CPU_CORES` in `mech.stats` is otelcol's self-report, a cross-check.
- `mech_notes`: always ends `scraper_rate_invariant`; before it, when non-zero:
  `refused`, `receiver_failed`, `send_failed`, `scraper_errored`, `inflight` (accepted −
  sent − send_failed at the final read: points still in the batch processor or queue),
  `log_errors`, `queue_gauge_absent`, `queue_capacity=X!=512`, `detach_killed`.
- Per bundle in `mech.stats`: `OTEL_SCOPE`, `OTEL_SCRAPE_INTERVAL_S`, `OTEL_RECEIVER_COUNT`,
  `OTEL_HOSTMETRICS_SCRAPERS`, queue/batch sizes, `OTEL_ATTACH_S`, `OTEL_WINDOW_S`,
  `OTEL_SCRAPES_EXPECTED`, scraped/errored (scraper side), accepted total / nginx /
  hostmetrics, refused, failed, sent, send_failed, `OTEL_INFLIGHT`, queue size and capacity
  gauges, RSS, self CPU, log error/warn counts. The rendered `otelcol.yaml` and `otelcol.log`
  stay in the bundle.

## Read every result with these caveats

- **Rate-invariant by construction.** The scraper's cost tracks scrape interval × receiver
  count, not nginx's request rate (S: narrow 0.0002–0.0003 cores flat, wide 0.20→0.24 cores
  while load rose 4×). It belongs on no crossover plot against perf or eBPF. Its drop rate is
  computed with the shared definition but counts metric points, not workload events, so it is
  not comparable with the other mechanisms' drop rates either; zero drops at queue 0/512 means
  the configuration never backed up, not that the collector is lossless under load.
- **The scope step changes two things at once** here (S's doc says three; topology is not
  varied in either implementation): receivers 1 → 9 scrapers and interval 15 s → 1 s. The
  narrow-to-wide effect cannot be attributed to either alone. The disambiguation arm (wide
  receivers at 15 s) is not written.
- S's wide cells roughly doubled p999 at 17–59 % aggregator-cpuset use, but were co-located,
  so biased in an unknown direction. This layout is the isolated measurement; compare with S
  only as a side note.
- The debug exporter ships nothing: CPU is receive + process + serialise, a lower bound on a
  deployment that exports.

## Not done

- **OTLP (rate-responsive) arm.** Needs a span source in nginx (the stock image emits none) and
  span-scoped counters in `mech_stats` and the CSV in the same edit; every counter here is
  metric-point scoped, so an OTLP run would count zero spans while looking complete. S's
  `otelcol_otlp.yaml.template` is not ported. `mech_preflight` refuses any mode but `scraper`.
- The disambiguation arm above; `wide-allcpu` (meaningless here: wide is already host-wide).

## Unverified until check.sh runs

- That `otelcol_receiver_accepted_metric_points` carries `receiver="nginx"` /
  `receiver="hostmetrics"` labels in 0.161.0's exposition (S summed over labels and never
  filtered). If the label differs, `mech_sanity` fails the run (0 nginx points) — loud, not
  silent.
- otelcol's console log format (`<ts>\t<level>\t…`) for the error count.
- That `/proc/<pid>/comm` reads `otelcol-contrib` (15 chars, the kernel's comm limit).
