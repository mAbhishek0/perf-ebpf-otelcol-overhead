#!/usr/bin/env python3
"""bcc_tracer.py — userspace half of the nginx x eBPF pair (BCC).

Ported from the Platform S pipeline (docs/drafts/nginx-perf-pipeline-server/
ebpf/bcc_tracer.py). Same probes, buffer and filter checks; three changes for
the laptop harness:
  * it runs until mech_detach sends SIGINT (like perf), not for a fixed
    duration; --max-window bounds it so it can never be orphaned, and hitting
    that bound is a failure, not a stop;
  * the stats file is KEY='value' (the harness's kv format), EBPF_EXIT last;
  * no bpf_stats arm (kernel.bpf_stats_enabled stays 0, see LESSONS), so no
    bpftool calls.

Usage (from mech.sh):
  bcc_tracer.py --scope narrow|wide --stats OUT --ready FILE --buffer-pages N
                [--pids 1,2] [--cpus 0,2] [--summary-out FILE] --max-window S
"""
import argparse
import ctypes
import os
import signal
import sys
import time

TRACED_CPUS_SLOTS = 1024          # BPF_ARRAY(traced_cpus, u8, 1024) in nginx_probes.c
CTR_SUBMITTED, CTR_SUBMIT_FAIL, CTR_FILTERED, CTR_SECONDARY, CTR_SLOTS = 0, 1, 2, 3, 4


def parse_args(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--scope", required=True, choices=("narrow", "wide"))
    p.add_argument("--stats", required=True)
    p.add_argument("--ready", required=True)
    p.add_argument("--buffer-pages", required=True, type=int)
    p.add_argument("--pids", default="")
    p.add_argument("--cpus", default="")
    p.add_argument("--summary-out", default="")
    p.add_argument("--max-window", required=True, type=int)
    return p.parse_args(argv)


def parse_id_list(raw, what):
    """Comma-separated non-negative integers, or a hard failure: a silently
    dropped filter entry traces less than the scope label says."""
    out = []
    for piece in raw.split(","):
        piece = piece.strip()
        if not piece:
            continue
        if not piece.isdigit():
            raise SystemExit("bcc_tracer: %s has a non-integer entry: %r" % (what, piece))
        out.append(int(piece))
    if not out:
        raise SystemExit("bcc_tracer: %s is empty; a filter matching nothing reads as "
                         "'eBPF costs nothing'" % what)
    return out


def check_buffer_pages(pages):
    """BCC rounds silently; the recorded size must be the one used."""
    if pages <= 0 or (pages & (pages - 1)) != 0:
        raise SystemExit("bcc_tracer: --buffer-pages must be a power of two (got %d)" % pages)


def check_cpus(cpus):
    for cpu in cpus:
        if cpu >= TRACED_CPUS_SLOTS:
            raise SystemExit("bcc_tracer: CPU id %d >= %d traced_cpus slots; it would read "
                             "as 'not traced'" % (cpu, TRACED_CPUS_SLOTS))


def kv_lines(pairs):
    """The harness's kv format; quotes are stripped from values as kv_put does."""
    return "".join("%s='%s'\n" % (k, str(v).replace("'", "")) for k, v in pairs)


class Tracer(object):
    def __init__(self, args):
        self.args = args
        self.received = 0
        self.lost = 0
        self.stop = None          # None while running; then "signal" or "max_window"
        self.filter_size = 0

    # Increment-and-return: the per-event Python cost is the mechanism's
    # userspace cost (S: ~3.5-5.4 us per event), so keep it minimal.
    def on_event(self, cpu, data, size):
        self.received += 1

    def on_lost(self, lost):
        self.lost += lost

    def run(self):
        a = self.args
        check_buffer_pages(a.buffer_pages)
        try:
            from bcc import BPF
        except ImportError as exc:
            raise SystemExit("bcc_tracer: cannot import bcc (%s)" % exc)
        src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "nginx_probes.c")
        cflag = "-DSCOPE_NARROW" if a.scope == "narrow" else "-DSCOPE_WIDE"
        bpf = BPF(src_file=src, cflags=[cflag])
        try:
            self._populate_filter(bpf)
            bpf["events"].open_perf_buffer(self.on_event, page_cnt=a.buffer_pages,
                                           lost_cb=self.on_lost)
            self._handle_signals()
            self._signal_ready()
            deadline = time.time() + a.max_window
            while self.stop is None:
                bpf.perf_buffer_poll(timeout=200)
                if time.time() >= deadline:
                    self.stop = "max_window"
            # Drain what was already submitted, so received + lost accounts for
            # the kernel's submitted count (cross-checked in mech.sh).
            for _ in range(5):
                bpf.perf_buffer_poll(timeout=0)
            counters = self._read_counters(bpf)
            summary = self._read_syscall_summary(bpf) if a.scope == "wide" else None
        finally:
            try:
                bpf.cleanup()
            except Exception:
                pass
        if summary is not None and a.summary_out:
            self._write_syscall_summary(summary)
        self._write_stats(counters)
        return 0 if self.stop == "signal" else 1

    def _populate_filter(self, bpf):
        """Write the scope filter and verify every entry took."""
        a = self.args
        if a.scope == "narrow":
            pids = parse_id_list(a.pids, "--pids")
            table = bpf["target_pids"]
            for pid in pids:
                table[ctypes.c_uint(pid)] = ctypes.c_ubyte(1)
            stored = sum(1 for _ in table.items())
            if stored != len(pids):
                raise SystemExit("bcc_tracer: %d worker PIDs asked, map holds %d" % (len(pids), stored))
            self.filter_size = len(pids)
        else:
            cpus = parse_id_list(a.cpus, "--cpus")
            check_cpus(cpus)
            table = bpf["traced_cpus"]
            for cpu in cpus:
                table[ctypes.c_int(cpu)] = ctypes.c_ubyte(1)
            for cpu in cpus:
                if table[ctypes.c_int(cpu)].value != 1:
                    raise SystemExit("bcc_tracer: traced_cpus[%d] did not read back as 1" % cpu)
            self.filter_size = len(cpus)

    def _handle_signals(self):
        def stop(signum, _frame):
            self.stop = "signal"
        signal.signal(signal.SIGINT, stop)
        signal.signal(signal.SIGTERM, stop)

    def _signal_ready(self):
        # Written only after the probes are attached and the buffer is open.
        with open(self.args.ready, "w") as fh:
            fh.write("attached\n")
            fh.flush()
            os.fsync(fh.fileno())

    def _read_counters(self, bpf):
        table = bpf["counters"]
        totals = [0] * CTR_SLOTS
        for slot in range(CTR_SLOTS):
            for per_cpu in table[ctypes.c_int(slot)]:
                totals[slot] += per_cpu
        return totals

    def _read_syscall_summary(self, bpf):
        out = [(int(k.value), int(v.value)) for k, v in bpf["syscall_counts"].items()]
        out.sort(key=lambda kv: (-kv[1], kv[0]))
        return out

    def _write_syscall_summary(self, summary):
        with open(self.args.summary_out, "w") as fh:
            fh.write("# per-syscall counts in the workload CPUs over the tracer's life\n")
            fh.write("# (perf trace --summary analogue; not parsed)\n# syscall_nr count\n")
            for nr, count in summary:
                fh.write("%d %d\n" % (nr, count))
            fh.write("# total %d\n" % sum(c for _, c in summary))

    def _write_stats(self, counters):
        """Every key every run; EBPF_EXIT last, so a truncated file is refused."""
        pairs = [
            ("EBPF_LIBRARY", "bcc"),
            ("EBPF_SCOPE", self.args.scope),
            ("EBPF_FILTER_ENTRIES", self.filter_size),
            ("EBPF_PERF_BUFFER_PAGES", self.args.buffer_pages),
            ("EBPF_EVENTS_RECEIVED", self.received),
            ("EBPF_EVENTS_LOST", self.lost),
            ("EBPF_KERNEL_SUBMITTED", counters[CTR_SUBMITTED]),
            ("EBPF_KERNEL_SUBMIT_FAILED", counters[CTR_SUBMIT_FAIL]),
            ("EBPF_KERNEL_FILTERED", counters[CTR_FILTERED]),
            ("EBPF_KERNEL_SECONDARY", counters[CTR_SECONDARY]),
            ("EBPF_STOP", self.stop),
            ("EBPF_EXIT", "ok" if self.stop == "signal" else "stopped_" + str(self.stop)),
        ]
        tmp = self.args.stats + ".partial"
        with open(tmp, "w") as fh:
            fh.write(kv_lines(pairs))
            fh.flush()
            os.fsync(fh.fileno())
        os.rename(tmp, self.args.stats)


def main(argv=None):
    return Tracer(parse_args(argv)).run()


if __name__ == "__main__":
    sys.exit(main())
