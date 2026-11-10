"""Logic tests for bcc_tracer.py --uprobe, run with `python3 -I`. bcc is imported
only inside Tracer.run(), so none of this needs bcc, root or hardware."""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(HERE, "..", "..", "..", "common", "mech", "bcc_tracer.py")
spec = importlib.util.spec_from_file_location("bcc_tracer", PATH)
bt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bt)

fails = []


def check(name, cond):
    if not cond:
        fails.append(name)
        print("FAIL: " + name)


def dies(fn, *a):
    try:
        fn(*a)
    except SystemExit as exc:
        return exc.code != 0
    return False


base = ["--scope", "narrow", "--src", "x.c", "--stats", "s", "--ready", "r",
        "--buffer-pages", "512", "--max-window", "9", "--pids", "42"]

# absent: nothing changes for nginx and fio
check("absent -> None", bt.check_uprobe_args(bt.parse_args(base)) is None)

a = bt.parse_args(base + ["--uprobe", "/proc/42/root/usr/local/bin/redis-server:call:on_call"])
check("split", bt.check_uprobe_args(a) == ("/proc/42/root/usr/local/bin/redis-server", "call", "on_call"))
check("colon in path survives", bt.parse_uprobe("/a:b/bin:call:on_call") == ("/a:b/bin", "call", "on_call"))
for raw in ("", "x", "a:b", ":call:on_call", "/bin::on_call", "/bin:call:", "  :call:on_call"):
    check("malformed refused: %r" % raw, dies(bt.parse_uprobe, raw))
a = bt.parse_args(base + ["--uprobe", "/b:call:f", "--uprobe", "/b:call:g"])
check("twice refused", dies(bt.check_uprobe_args, a))
wide = ["--scope", "wide", "--src", "x.c", "--stats", "s", "--ready", "r",
        "--buffer-pages", "512", "--max-window", "9", "--cpus", "0",
        "--uprobe", "/b:call:f"]
check("wide refused", dies(bt.check_uprobe_args, bt.parse_args(wide)))
check("bcc not imported at module level", "bcc" not in sys.modules)

print("uprobe arg tests: %d failed" % len(fails))
sys.exit(1 if fails else 0)
