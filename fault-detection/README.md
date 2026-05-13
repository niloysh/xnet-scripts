# fault-detection — xnet-rca client scripts

Two scripts for consuming the xnet-rca framework once it's installed in
your namespace. The framework deploys (via Helm) a continuous chaos
sweeper, UE-side probe, and a snapshot HTTP service; these scripts let
you pull live data or materialize a labeled offline dataset.

Source: [github.com/niloysh/xnet-fault-detection](https://github.com/niloysh/xnet-fault-detection)

## Prerequisites

- `kubectl` with credentials for the cluster.
- The `xnet-rca` Helm release installed in your tenant namespace (the
  framework owner provisions this for you). Verify with:
  ```bash
  kubectl -n <ns> get pods -l app.kubernetes.io/instance=xnet-rca
  ```
- For `xnet-rca-live.py`: Python 3.10+ (stdlib only — no pip install).

## xnet-rca-export.sh — pull an offline dataset

Submits an in-cluster Pod that runs `xnet-rca-export` against the cluster's
VictoriaMetrics / VictoriaLogs, then tar-streams the per-scenario artifacts
back to your laptop.

```bash
# Last hour:
./xnet-rca-export.sh -n <ns> -w 1h -o ./out

# Specific time range, with pod logs included:
./xnet-rca-export.sh -n <ns> -o ./paper_dataset \
    -- --start 2026-05-13T05:50:00Z --end 2026-05-13T06:30:00Z --include-logs

# Subset of fault families:
./xnet-rca-export.sh -n <ns> -w 6h -o ./cpu_only -- --fault-types cpu_stress
```

### Output structure

```
out/
├── 20260513T055933Z_cpu_stress_gnb2_9a4baa20/
│   ├── metrics.parquet         # 1Hz wide DataFrame, MultiIndex columns (metric, target)
│   ├── kpi.csv                 # slice, ue_pod, t_rel_s, kpi_bps, loss_pct, avg_rtt_ms
│   ├── ground_truth.json       # scenario_id, fault.{type,target,...}, eval_window, kpi_summary
│   └── plots/
│       ├── root_metric.png
│       └── kpi.png
├── ... (one dir per fault scenario)
└── manifest.jsonl              # one row per exported scenario
```

Dir name format: `<actual_start_iso>_<fault_type>_<target>_<scenario_id_short>`
— sortable alphabetically + human-readable.

## xnet-rca-live.py — consume the live snapshot API

The framework exposes `xnet-rca-feed.<ns>:8080` inside the cluster. This
script handles the port-forward and demonstrates the polling pattern.

```bash
# One-shot, pretty-printed JSON (sanity check):
./xnet-rca-live.py snapshot -n <ns> --window-s 60

# Poll forever — replace on_snapshot() with your detector:
./xnet-rca-live.py poll -n <ns> --window-s 60 --interval-s 30

# If your detector runs inside the cluster, skip the port-forward:
./xnet-rca-live.py poll -n <ns> --url http://xnet-rca-feed.<ns>:8080
```

### `/snapshot` API schema

```jsonc
{
  "start": 1778654006.5,        // unix seconds, window start
  "end":   1778654066.5,        // unix seconds, window end
  "metrics": [                  // long format; pivot to wide if you want
    {"ts": 1778654006, "metric": "cpu_usage_rate", "target": "upf1", "value": 0.42},
    ...
  ],
  "kpi": [                      // one row per UE-probe sample
    {"slice": "1-000001", "ue_pod": "ueransim-ue1-...",
     "ts": 1778654006, "kpi_bps": 700000, "loss_pct": 0, "avg_rtt_ms": 3.2},
    ...
  ],
  "logs": [],                   // empty unless include_logs=true
  "active_fault": {             // null when no fault is active
    "fault_type":   "cpu_stress",
    "target":       "upf1",
    "target_class": "upf",
    "slice":        "1-000001",
    "scenario_id":  "9a4baa20a134",
    "params":       "load_pct=95,workers=8"   // sorted "k=v,k=v"; "" for binary faults
  }
}
```

Query params: `window_s` (int, required), `end_unix` (float, default now),
`include_logs` (bool, default false), `log_limit` (int, default 1000),
`step_s` (int, default 1).

### Fault families currently injected

| family | target classes | dial sample space |
|---|---|---|
| `cpu_stress` | `upf`, `smf`, `gnb` | `load_pct ∈ {85, 95}`, `workers ∈ {4, 8}` |
| `gnb_to_core_partition` | `gnb` | binary (100% packet drop on n3) |
| `gnb_to_core_loss` | `gnb` | `loss_pct ∈ {10, 30, 50, 70}` |
| `gnb_to_core_delay` | `gnb` | `latency ∈ {50ms, 100ms, 200ms, 400ms}`, `jitter ∈ {0ms, 20ms}` |
| `upf_bandwidth_cap` | `upf` | `rate ∈ {20kbps, 40kbps, 80kbps, 200kbps}` |

Default cadence: ~135s per scenario (120s + 15s pause). Roughly 80% of
iterations are faults, 20% baselines. The framework owner can tune
fault families, dials, and timing per-tenant via the Helm chart.
