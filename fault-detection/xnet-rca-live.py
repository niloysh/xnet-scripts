#!/usr/bin/env python3
"""Reference client for the xnet-rca-feed live snapshot API.

Two modes:

  one-shot:  fetch a single snapshot, pretty-print the schema, exit.
             Useful as a "did I install this right?" check.

      bin/xnet-rca-live.py snapshot -n n6saha --window-s 60

  poll:      run forever; fetch a snapshot every --interval-s seconds and
             call a stub `on_snapshot()` you can replace with your detector.

      bin/xnet-rca-live.py poll -n n6saha --interval-s 30 --window-s 60

Both modes open a kubectl port-forward to `svc/xnet-rca-feed` in the target
namespace (and tear it down on exit). For in-cluster consumers, pass
`--url http://xnet-rca-feed.<namespace>:8080` to skip the port-forward.

What the snapshot contains (see scenarios/sweep/live.py for the source of truth):

    start, end       float unix seconds — the window the snapshot covers
    metrics          list[{ts, metric, target, value}]
                     long-format. Pivot to wide via:
                         df.pivot_table(index='ts', columns=['metric','target'], values='value')
    kpi              list[{slice, ue_pod, ts, kpi_bps, loss_pct, avg_rtt_ms}]
                     one row per UE-probe sample
    logs             list[dict]  — only populated if --include-logs
    active_fault     {fault_type, target, target_class, slice, scenario_id} | None
                     None = no fault active right now; otherwise this is the
                     ground-truth label your detector should be predicting.

Replace `on_snapshot()` below with your detector. Everything else is plumbing.
"""
from __future__ import annotations

import argparse
import json
import signal
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from contextlib import contextmanager
from typing import Any


# ---------- transport ----------

@contextmanager
def port_forward(namespace: str, service: str = "xnet-rca-feed",
                 remote_port: int = 8080, local_port: int = 18080):
    """Spawn `kubectl port-forward` for the duration of the with-block."""
    pf = subprocess.Popen(
        ["kubectl", "-n", namespace, "port-forward", f"svc/{service}",
         f"{local_port}:{remote_port}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )
    # Wait for the forward to be ready (probe /health up to 10s).
    deadline = time.time() + 10
    base = f"http://127.0.0.1:{local_port}"
    while time.time() < deadline:
        try:
            urllib.request.urlopen(f"{base}/health", timeout=1).read()
            break
        except Exception:
            if pf.poll() is not None:
                err = pf.stderr.read().decode("utf-8", errors="replace") if pf.stderr else ""
                raise RuntimeError(f"port-forward died: {err.strip()}")
            time.sleep(0.5)
    else:
        pf.kill()
        raise RuntimeError("port-forward never became ready")
    try:
        yield base
    finally:
        pf.terminate()
        try:
            pf.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pf.kill()


def fetch_snapshot(base_url: str, *, window_s: int, include_logs: bool = False,
                   log_limit: int = 1000, step_s: int = 1) -> dict[str, Any]:
    """One GET /snapshot. Returns the decoded JSON dict."""
    qs = urllib.parse.urlencode({
        "window_s": window_s,
        "include_logs": str(include_logs).lower(),
        "log_limit": log_limit,
        "step_s": step_s,
    })
    with urllib.request.urlopen(f"{base_url}/snapshot?{qs}", timeout=30) as r:
        return json.loads(r.read())


# ---------- consumer (the part you'd replace) ----------

def on_snapshot(snap: dict[str, Any]) -> None:
    """Stub for your detector. Replace the body with inference + reporting.

    Default: print a one-line summary including the ground-truth label so you
    can sanity-check that scenarios are flowing through.
    """
    fault = snap["active_fault"]
    if fault:
        label = f"FAULT  {fault['fault_type']}/{fault['target']} sid={fault['scenario_id']}"
    else:
        label = "baseline"
    print(f"[{int(snap['end'])}] window={snap['end']-snap['start']:.0f}s "
          f"metrics={len(snap['metrics'])} kpi={len(snap['kpi'])} "
          f"logs={len(snap['logs'])}  {label}")


# ---------- CLI ----------

def _build_base_url(args) -> tuple[str, Any]:
    """Return (base_url, context_manager). If --url given, no port-forward."""
    if args.url:
        from contextlib import nullcontext
        return args.url, nullcontext(args.url)
    return None, port_forward(args.namespace, local_port=args.local_port)


def cmd_snapshot(args) -> int:
    _, cm = _build_base_url(args)
    with cm as base:
        snap = fetch_snapshot(base, window_s=args.window_s,
                              include_logs=args.include_logs,
                              log_limit=args.log_limit, step_s=args.step_s)
    summary = {
        "start": snap["start"],
        "end": snap["end"],
        "window_s": snap["end"] - snap["start"],
        "metrics_rows": len(snap["metrics"]),
        "metrics_sample": snap["metrics"][:3],
        "kpi_rows": len(snap["kpi"]),
        "kpi_sample": snap["kpi"][:3],
        "logs_rows": len(snap["logs"]),
        "active_fault": snap["active_fault"],
    }
    print(json.dumps(summary, indent=2))
    return 0


def cmd_poll(args) -> int:
    _, cm = _build_base_url(args)
    stop = {"flag": False}

    def _sigint(*_):
        stop["flag"] = True
    signal.signal(signal.SIGINT, _sigint)

    with cm as base:
        while not stop["flag"]:
            t0 = time.perf_counter()
            try:
                snap = fetch_snapshot(base, window_s=args.window_s,
                                      include_logs=args.include_logs,
                                      log_limit=args.log_limit,
                                      step_s=args.step_s)
                on_snapshot(snap)
            except Exception as exc:
                print(f"snapshot failed: {exc!r}", file=sys.stderr)
            elapsed = time.perf_counter() - t0
            sleep_for = max(0.0, args.interval_s - elapsed)
            if stop["flag"]:
                break
            time.sleep(sleep_for)
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="xnet-rca-live", description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("-n", "--namespace", required=True,
                        help="Target namespace where xnet-rca is installed")
    common.add_argument("--url", default=None,
                        help="Direct base URL (skips port-forward). "
                             "Use in-cluster: http://xnet-rca-feed.<ns>:8080")
    common.add_argument("--local-port", type=int, default=18080,
                        help="Local port for kubectl port-forward (default 18080)")
    common.add_argument("--window-s", type=int, default=60,
                        help="Snapshot window length in seconds (default 60)")
    common.add_argument("--include-logs", action="store_true",
                        help="Include pod logs in the snapshot (heavy)")
    common.add_argument("--log-limit", type=int, default=1000,
                        help="Cap log lines when --include-logs (default 1000)")
    common.add_argument("--step-s", type=int, default=1,
                        help="Metrics sampling step in seconds (default 1)")

    sp = sub.add_parser("snapshot", parents=[common],
                        help="Fetch one snapshot, print summary, exit")
    sp.set_defaults(func=cmd_snapshot)

    pp = sub.add_parser("poll", parents=[common],
                        help="Fetch snapshots forever; call on_snapshot() each round")
    pp.add_argument("--interval-s", type=float, default=30.0,
                    help="Seconds between snapshots (default 30)")
    pp.set_defaults(func=cmd_poll)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
