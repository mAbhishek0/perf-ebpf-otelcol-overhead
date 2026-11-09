# fio workload on Platform L

This folder holds the fio workload and its three mechanism pairs: `perf/`, `ebpf/` and `collector/`. Everything here is written and unit tested. **Nothing here has run on the laptop yet.** Read the hardware steps below before the first run.

## 1. What fio does here

fio does 4K random reads with `O_DIRECT`. The rate is fixed with `rate_iops`, which is fio's setting for how many I/Os per second one job may issue. The reads go to one 16 GiB file on an NVMe drive (a solid-state drive that connects over the PCIe bus; PCIe is the fast internal bus that links devices such as drives and graphics cards to the processor), which `fio/prepare.sh` writes once before any run (PLAN.md decision 3.3).

The reason is the laptop's SSD. It is a QLC drive (each flash cell stores four bits, which makes writes slow) with an SLC write cache (a small part of the drive that works as fast one-bit-per-cell flash). Sustained writes fill that cache, and the write speed then drops by 40 to 60 percent in the middle of a run. That would make the baselines drift. Reads of data that already exists avoid this. Each read is still one real block I/O for the tracers to see. `O_DIRECT` keeps the page cache from hiding the disk.

The constants are in `fio.env`. The engine is `libaio`. The job count (`FIO_NUMJOBS`, default 4) is one job per workload CPU. The queue depth (`FIO_IODEPTH`, default 32) is a pilot knob. Both are frozen into `fio/pilot.env` after the pilot.

## 2. How one run works

One fio process serves the whole run. Its job file has two groups, separated by `stonewall`.

1. The `ramp` group runs for `RAMP_S` (30 s) at the target rate. Nothing traces it. Its data is thrown away.
2. Each job of the `measure` group first runs `gate.sh` (through fio's `exec_prerun`). The gate writes a `ready.<pid>` file (PID is the process ID) and then waits for a file named `go`.
3. When every measure job is waiting at the gate, the harness attaches the tracer. The measure threads already exist at that moment, so `perf -p` can see them.
4. The harness then creates `go`. The measure group runs for `STEADY_S` (120 s).

The parser refuses any run whose measured time is more than 2 percent away from `STEADY_S`. So the gate can never shorten the window without being noticed.

fio runs in the transient scope `bench-fio-wl.scope`, under `bench.slice`. That cgroup gives `workload_cpu_cores`. A scope is removed when its last process exits. The harness reads the cgroup after the window. So the wrapper starts a `sleep 3600` in the scope before it starts fio. The sleeper keeps the cgroup alive. It uses no CPU. `wl_stop` stops the scope.

Before each cell try, the harness runs `fstrim` on the file system and then idles for 60 s (`FIO_CELL_IDLE_S`). This lets the drive finish its trim work before the warm-up.

## 3. What narrow and wide mean

| Mechanism | Narrow | Wide |
|---|---|---|
| perf | Samples the fio process at 99 Hz. | Samples the workload CPUs at 999 Hz and adds `perf trace`. |
| eBPF | Two block tracepoints, `block_rq_issue` and `block_rq_complete`. They are filtered by the test disk. | All system calls on the workload CPUs. This probe is byte-identical to nginx's. |
| Collector | Host disk metrics only, every 15 s. | All 8 host-metric scrapers, every 1 s. |

**Why eBPF narrow filters by device, not by process.** A block completion runs in the NVMe interrupt. In that interrupt the current task is whatever was interrupted. It is usually not fio. A filter on fio's PID would drop most completions. So the probe filters on the disk's device number. This is the alternate route in PLAN.md §6, taken from the start for this known reason.

The cost is that any other I/O on the same disk is traced too. Each run therefore records the disk's own read and write counts over the window (`FIO_DISK_READS_DELTA` and `FIO_DISK_WRITES_DELTA`). If those counts are well above fio's own I/O count, something else used the disk.

Each pair's own notes are in `perf/docs/README.md`, `ebpf/docs/README.md` and `collector/docs/README.md`.

## 4. What the columns mean for fio

- `throughput` is IOPS, in I/Os per second.
- `p50_ms` to `max_ms` are per-I/O latency in milliseconds. Each one is measured from submit to completion.
- `loadgen_cpu_cores` is fio's own CPU in cores. fio is its own load generator, so this is a cross-check of `workload_cpu_cores`. It is not a separate generator, and it is not comparable with nginx's wrk2 figure.
- The `tcp_*` columns are recorded but carry no meaning for fio. fio does no network I/O.

fio adds six columns of its own. They come after all the shared columns, so the shared column order is the same as for nginx. Each run's `wl.env` holds the same values under the key in brackets. `schema.json` lists each column's unit under `workload_column_units`.

- `fio_runtime_ms` (`FIO_RUNTIME_MS`): how long the measured part of the run lasted, in milliseconds. The parser refuses a run where this is more than 2 % away from the planned window.
- `fio_total_ios` (`FIO_TOTAL_IOS`): how many I/Os fio completed in the measured window, as a count.
- `fio_ramp_iops` (`FIO_RAMP_IOPS`): the I/Os per second of the untraced ramp group (`RAMP_S`) before the window. It is discarded from the results and kept only for the record.
- `fio_disk_reads_delta` (`FIO_DISK_READS_DELTA`): how many read requests the whole disk completed during the window, as a count. This includes reads by any program, not only fio.
- `fio_disk_writes_delta` (`FIO_DISK_WRITES_DELTA`): the same for write requests. fio itself writes nothing, so this counts other programs' writes.
- `gate_wait_s` (`GATE_WAIT_S`): how long the disk sat idle at the gate before the window, in seconds. It runs from the first job reaching the gate to the moment the harness lets the jobs go.

These columns were added before any fio data existed, so no frozen `schema.json` had to change.

## 5. Hardware steps, in order

Run these on the laptop, after `git pull`.

1. Run `grep IRQ_TIME_ACCOUNTING /boot/config-$(uname -r)`. Answer on the laptop (2026-11-09): **`# CONFIG_IRQ_TIME_ACCOUNTING is not set`**, so the option is off. (`CONFIG_HAVE_IRQ_TIME_ACCOUNTING=y` also appears; it only says the architecture supports the option.) Also run `df --output=source,target . /var/tmp` in the clone. Answer on the laptop (2026-11-09): both the clone and `/var/tmp` are on `/dev/nvme0n1p6`, mounted at `/`. Each run's provenance file now records the same line, and also `/proc/cmdline`, because `tsc=noirqtime` turns the option off at run time. What the option does: with `CONFIG_IRQ_TIME_ACCOUNTING=y`, the kernel takes hardirq and softirq time out of task run time. A hardirq is the first, urgent part of handling a device interrupt. A softirq is the deferred part that the kernel runs a little later. So that time is not charged to fio's cgroup and is not in `workload_cpu_cores`. It shows only in the `irq` and `softirq` columns of `/proc/stat`, which means only inside `busy_pct_workload`. With the option off, interrupt time is charged to whichever task was interrupted, which is fio or the idle task. This text first assumed that a stock Ubuntu kernel has the option on. The laptop's kernel does not, so the consequence is the "off" case. The completion probe of eBPF narrow runs inside the NVMe hardirq. When it interrupts fio, its cost is charged to fio and lands in `workload_cpu_cores`. When it interrupts the idle task, that cost is not in `workload_cpu_cores` at all. `busy_pct_workload` sees interrupt time only through tick sampling, which is coarse. See the caveat in section 6.
2. Run `sudo bash fio/prepare.sh`. Then leave the laptop idle for 30 minutes, so the drive can move the new data out of its SLC cache.
3. Run `sudo bash pilot.sh fio`. It takes about 1 hour. Read `fio/pilot/pilot_report.txt`. Then write `fio/pilot.env` by hand. It sets `LADDER`, `FIO_NUMJOBS` and `FIO_IODEPTH`. The top of `LADDER` must be the highest rate fio sustains without a tracer (PLAN.md decision 3.2). If no rate saturates, repeat with higher `--rates` and `--out pilot-2`.
4. Run `sudo bash fio/check.sh`. It takes about 15 minutes. Push `logs/fio-check_*.txt`. Copy one real `fio.json` from `state/fio-check/<ts>/` to `fio/tests/fixtures/fio_L.json`. Add a test that parses it.
5. Run `sudo bash run_workload.sh fio --mech perf --smoke`. Check by hand that warm-ups 2 and 3 match A1.
6. Run the matrix nights as in PLAN.md §4. Perf and eBPF block 1 on Nov 12. Collector block 1 and perf block 2 on Nov 13. eBPF and collector block 2 on Nov 14. A block 1 command is `sudo bash run_workload.sh fio --mech <m>`. A block 2 command adds `--block 2`.

If the pilot shows the baselines drifting (A1 and A2 p99 far apart on untraced runs), PLAN.md §6 applies. Switch to `null_blk`. Decide this by Nov 12.

## 6. Known caveats

These also go into the paper.

- **NVMe interrupts land on the workload CPUs.** NVMe uses managed per-CPU interrupts. `host.sh` cannot move them to CPUs 12 and 14. This is the same in baseline and traced runs. It matters most for eBPF narrow, because its completion probe runs inside those interrupts.
- **Interrupt time is not accounted separately on the laptop.** The laptop's kernel has `CONFIG_IRQ_TIME_ACCOUNTING` off (section 5, step 1). So hardirq and softirq time is charged to whichever task was interrupted. Part of eBPF narrow's probe cost is therefore inside `workload_cpu_cores` (when the probe interrupts fio), and part is missing from it (when the probe interrupts the idle task). The split is not under our control. `workload_cpu_cores` for eBPF narrow is a mix of fio's own CPU and some tracer CPU, and should be reported that way. On a kernel with the option on, the probe's cost would instead be absent from `workload_cpu_cores`. So this column is not comparable with a platform whose kernel differs; check the provenance file first.
- **eBPF narrow uses a device filter, not a PID filter.** Any other I/O on `nvme0n1` during a window is traced too. `FIO_DISK_READS_DELTA` and `FIO_DISK_WRITES_DELTA` measure how much there was.
- **The device filter assumes a plain partition or a whole disk.** Under LVM (logical volume manager) or LUKS (disk encryption), the parent of the device is a device-mapper device, not a disk. The run then stops with a clear error. Nothing is silently wrong.
- **`loadgen_cpu_cores` is fio's CPU.** It is not comparable with nginx's wrk2 figure.
- **fio's rate limiter can issue I/O in small bursts.** This happens when `rate_iops` is used with `iodepth` above 1. Latency is per I/O, from submit to completion. So it includes any queueing the bursts cause. This is the same in every arm.
- **The collector's wide cell is not identical across workloads.** For nginx, wide runs the receivers `[nginx, hostmetrics]`. For fio, wide runs `[hostmetrics]` only. Both use the same 8 scrapers and the same 1 s interval. So fio's wide collector cell has one receiver fewer than nginx's. Keep this in mind whenever "wide" is compared across workloads.
- **Traced and baseline runs wait at the gate for different times.** The disk sits idle while `mech_attach` runs. For a baseline that is well under 1 s. For perf it is a few seconds. For BCC it is longer, because BCC compiles its probe first. For the collector it can be up to `COLLECTOR_ATTACH_TIMEOUT_S`, which is 30 s. An NVMe drive can enter deep power states on its own, and the CPUs can enter deep idle states. This may happen only in traced runs. A traced window may then open on a device that is still waking up. This is the same kind of traced-only start-of-window effect that was seen for nginx (README timelines 32 and 33). Each run now records `GATE_WAIT_S` (CSV column `gate_wait_s`) and the NVMe power-state setting (`NVME_DEFAULT_PS_MAX_LATENCY_US`), so this can be checked. `GATE_WAIT_S` understates the real idle time by up to 0.05 s, because the jobs check for the harness's go signal only every 50 ms. It is measured with the realtime clock, so a clock adjustment during the wait would distort it. Whether to equalise the wait is still an open decision.
- **perf writes `perf.data` to the disk under test.** perf writes `perf.data` into the run folder, and only in traced perf runs. Wide perf also writes `perf_trace.out`, a small summary that `perf trace` writes when it exits. The run folder is on the root file system. The probe puts `FIO_DIR` (`/var/tmp`) on `nvme0n1p6`, the same disk as fio's file. On the laptop the clone is on that file system too (confirmed 2026-11-09, section 5, step 1). For the same reason, background writes by the operating system (journald, apt, logs) go to the same disk and file system as fio's file, in every arm; `FIO_DISK_WRITES_DELTA` measures them. perf compresses the file with zstd (a fast compression tool) after the window. `FIO_DISK_WRITES_DELTA` records the writes inside the window, and `check.sh` shows them as `disk_wr`. Whether perf output should move to tmpfs (a file system held in memory, so it does not touch the disk) for fio is decided after `check.sh` has run.
- **The pilot differs from a matrix cell.** The pilot does not run `wl_cell_prep` (no trim and no idle before each pilot point). It also writes no provenance file. So calibration runs in a different disk state from the matrix cells.
- **fio-specific values are in the CSV.** `FIO_RUNTIME_MS`, `FIO_TOTAL_IOS`, `FIO_RAMP_IOPS`, `FIO_DISK_READS_DELTA`, `FIO_DISK_WRITES_DELTA` and `GATE_WAIT_S` are CSV columns, after the shared ones (section 4). Each run's `wl.env` also keeps them.
- **The test fixture is synthetic.** `fio/tests/fixtures/fio_synthetic.json` stands in until step 4 replaces it with real laptop output.
- **Nothing here has run on hardware.** No number from fio exists yet.
