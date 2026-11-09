# fio x perf (Platform L)

Narrow means `perf record` samples the fio process at 99 Hz. Wide means `perf record` samples the workload CPUs at 999 Hz, and `perf trace` records every system call on those CPUs. By the time perf attaches, the fio measure threads already exist, because they wait at the gate. So `perf -p` sees them. Unrun on hardware.

See [fio/README.md](../../README.md) for how a fio run works, what the columns mean, the hardware steps and the known caveats.
