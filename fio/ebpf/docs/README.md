# fio x eBPF (Platform L)

Narrow means two block tracepoints, `block_rq_issue` and `block_rq_complete`. They are filtered in the kernel by the test disk's device number, not by fio's PID. A completion runs in the NVMe interrupt, where the current task is not fio. Other I/O on the same disk is traced too. Each run records the disk's own I/O counts, to show how much there was. Wide means all system calls on the workload CPUs. The wide probe is byte-identical to nginx's. The probe source is `scripts/fio_probes.c`. Unrun on hardware.

See [fio/README.md](../../README.md) for how a fio run works, what the columns mean, the hardware steps and the known caveats.
