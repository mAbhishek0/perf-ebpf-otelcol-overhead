# redis x OpenTelemetry Collector (Platform L)

Status: written 2026-11-11, never run on hardware. Only `bash -n` and the logic
tests (`bash redis-memtier/collector/tests/test_mech.sh`) have run. The redis
workload is described in `docs/plans/2026-11-11-redis-implementation.md`
(decision R14 covers this pair).

## What is collected

The collector is `otelcol-contrib` 0.161.0 in scraper mode. A scraper reads
numbers on a timer. Nothing is pushed to it.

| scope | receivers | hostmetrics scrapers | interval |
|---|---|---|---|
| narrow | `redis` | 0 | 15 s |
| wide | `redis` + `hostmetrics` | 8 | 1 s |

- The `redis` receiver runs `INFO` against `127.0.0.1:6379` over plain TCP.
  Its default is no TLS, so the template has no TLS block.
- The 8 hostmetrics scrapers are cpu, memory, disk, network, load, filesystem,
  paging and processes. They are the same as in the nginx pair. They read the
  whole host, so they are not specific to redis.
- This is the same shape as the nginx pair: 1 receiver narrow, 2 receivers wide.

## What is identical to the nginx pair

The two templates are copies of the nginx ones with one change: the receiver
`nginx` became `redis`. Every other line that is not a comment is the same
(batch processor, debug exporter, sending queue, self-telemetry). The test
checks this with a byte comparison. The constants are in
`common/mech/collector.env`.

## Two things that differ in the code

- **Endpoint.** The shared renderer has one placeholder, `__NGINX_STATUS_URL__`,
  whose name is historical. For redis, `collector_status_url` fills it with
  `127.0.0.1:<REDIS_PORT>`, not a URL.
- **Per-receiver count.** `common/mech/collector.sh` only writes the accepted
  count for `nginx` and `hostmetrics`. This pair's `mech.sh` wraps `mech_stats`
  and adds `OTEL_REDIS_ACCEPTED_METRIC_POINTS`, read from the `receiver="redis"`
  label. `common/` was not changed.

## Checks that stop a bad run

- Before otelcol starts, `redis-cli PING` must answer `PONG`. A dead endpoint
  would otherwise give an arm of zeros that looks complete.
- After the run, redis must have accepted more than 0 points in both scopes.
  In wide, hostmetrics must also have accepted more than 0, and the exporter
  must have sent more than 0.
- The rendered config must have 1 receiver and 0 scrapers (narrow) or
  2 and 8 (wide). Anything else refuses the run.

## How to run (always as root, from the laptop tree)

1. Smoke: `sudo bash redis-memtier/collector/scripts/run.sh --smoke`.
2. Full: `sudo bash redis-memtier/collector/scripts/run.sh`.
   If it dies, `sudo bash revert.sh` restores the host.

There is no `check.sh` for this pair yet.

## Read every result with these caveats

- **Rate-invariant by construction.** The cost follows the scrape interval and
  the number of receivers. It does not follow the redis command rate. Keep it
  off any crossover plot against perf or eBPF.
- The step from narrow to wide changes two things at once: the number of
  receivers and the interval (15 s to 1 s). The effect cannot be split between them.
- redis's `INFO` output is read by the collector's own connection. Those
  commands are counted by redis, so the redis command counts include them
  (decision R10 notes this).
- The debug exporter ships nothing, so the CPU measured is a lower bound for a
  deployment that really exports.
- The number of metric points per scrape (about 30 to 40) is an estimate until
  a shakedown measures it.

## Unverified until a run happens

- That the exposition carries `receiver="redis"` in 0.161.0. If not, the sanity
  check fails the run loudly with "accepted 0 redis metric points".
