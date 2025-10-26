# Finetuning Guide for PVS Amplified Research (64Hz Subtick Adaptation)

**Purpose:**
This guide provides detailed instructions for fine-tuning the server-side visibility plugin for CS2 using SourceMod 1.12 on **64-tick servers with subtick awareness**. The goal is to maximize accuracy, reduce server CPU load, and maintain privacy while enabling research-oriented spotting analytics.

## Goals of Finetuning

* Maximize **spot accuracy** with minimal false positives/negatives.
* Minimize **server CPU usage** (traces are computationally expensive).
* Maintain **low latency** for spotted updates (~150–400 ms due to subtick granularity).
* Ensure **no positional telemetry** leaks — only enemy ID, expiry, and coarse zone.

## Key Parameters (ConVars) for 64Hz Subtick

| ConVar                     | Default   | Description                                         | Recommendations                                                                                  |
| -------------------------- | --------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| pvsamp_check_interval      | 0.12      | Interval in seconds for visibility checks           | 0.10–0.14 for 64-tick subtick servers; smaller intervals improve responsiveness but increase CPU |
| pvsamp_broadcast_interval  | 0.25      | How often the server broadcasts spotted enemies     | 0.20–0.30; lower = snappier, higher = reduced messages                                           |
| pvsamp_max_los_samples     | 3–4       | Number of ray samples per target                    | 3–5; fewer for large matches, more for small matches to reduce false negatives                   |
| pvsamp_max_checks_per_tick | 256       | Global trace budget per tick                        | 128–512 depending on player count and CPU capacity                                               |
| pvsamp_spot_expiry         | 2.5       | Duration in seconds a spot persists since last seen | 2–3.5 seconds, balance accuracy vs stale spots                                                   |
| pvsamp_distance_cull       | 1200–1500 | Maximum distance to consider a target               | Tune per map, lower values reduce CPU on large matches                                           |
| pvsamp_fov_cos             | 0.4–0.5   | Cosine threshold for FOV culling                    | 0.35–0.55 depending on permissiveness                                                            |

## Trace Sampling Strategy

* Prioritize head → chest → legs → offsets.
* Lateral offsets ±10–15 units to reduce false negatives.
* Consider reducing sample count for distant targets to save CPU.

## Caching & Invalidation

* Cache visibility results for ~25–100% of `pvsamp_spot_expiry`.
* Invalidate if entities move >20–40 units or have sudden velocity changes.
* Subtick-aware updates ensure smoother transitions between subticks.

## Staggering & Budgeting

* Spread viewer-target pairs across subticks to prevent CPU spikes.
* Prioritize closer targets and recently moving players.
* Compute per-viewer cap: `perViewerCap = max(1, floor(maxChecks / maxViewers))`.

## Coarse Zone Design

* Divide maps into ~6–12 zones (A_site, B_site, Mid, etc.).
* Zones are identifiers only; no coordinates sent.
* Use zones for UI hints.

## Logging & Metrics

* Log format: `[timestamp] team=T spotted: enemy=ID expiry=+Xs method=sampled/n`.
* Track traces/sec, checks per tick, false positives/negatives.
* Capture `pvs_spotted` packets to confirm no coordinates are sent.

## Validation Tests

1. Controlled sighting tests with thin cover to verify multi-sample accuracy.
2. Latency test: aim for <400 ms from sighting to spotted broadcast.
3. Load test: simulate peak players and movement to check CPU and trace usage.
4. Confirm no-coordinate messages.

## Anti-abuse & Hardening

* Rate-limit broadcasts per team.
* Exclude spectators from broadcasts.
* Audit server events for telemetry leaks.

## Server Profiles for 64Hz Subtick

* **Standard 64-tick Subtick:** Check Interval 0.12s, Broadcast 0.25s, Max Samples 4, Max Checks 256, Spot Expiry 2.5s, Distance Cull 1400, FOV Cos 0.45
* **Light Load:** Check Interval 0.14s, Broadcast 0.28s, Max Samples 3, Max Checks 128, Spot Expiry 2.0s, Distance Cull 1200, FOV Cos 0.4
* **High Accuracy Test:** Check Interval 0.10s, Broadcast 0.22s, Max Samples 5, Max Checks 384, Spot Expiry 3.5s, Distance Cull 1500, FOV Cos 0.5
