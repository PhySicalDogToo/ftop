# Network ranking loading and retention — 2026-10-20

## Behavior

- A cold network ranking shows “数据读取中” / “Reading data…” while the native
  reader establishes a rate baseline. The existing row or strip slot reserves
  its geometry. Loading, an empty valid sample, stopped collection and an actual
  failure remain distinct; unknown rates are never shown as measured zero.
- Leaving download/upload for CPU or memory retains the reader and its baseline
  for 20 seconds. Returning to either network ranking cancels the pending stop.
  CPU/memory switches and sampling restarts do not extend the original deadline.
  At expiry, the sampler pushes stopped state immediately, independently of the
  hardware refresh interval. Hide/occlusion, process-module removal and shutdown
  stop immediately; waking starts with a clean baseline.
- Removed the idle process-card instruction to select a network ranking. Actual
  reader errors and the existing local/proxy/TUN attribution explanation remain.
- Native frame freshness still has a six-second bound. Cumulative byte deltas
  accept a finite positive elapsed interval, so the supported ten-second panel
  refresh does not leave the ranking permanently loading.

## Automated gate and lifecycle checks

- `scripts/check.sh` passed strict formatting, the warnings-as-errors build and
  two complete runs of **273 tests** on the final sources. Targeted suites also
  passed: 10 collection-controller tests, 17 provider tests and 15 network UI tests.
- Controller tests use an injected monotonic clock and scheduler: initial CPU-only
  demand, 19.999/20-second boundary, rapid return, fixed departure deadline,
  obsolete cancellation callbacks, early callbacks, overdue return, immediate
  stop, ineligible/menu-bar-only collection and one-shot CLI demand.
- UI tests cover warm preservation, cold/stale return, first snapshot missing,
  loading text in list and strip forms, unchanged geometry and the removed idle
  instruction. Genuine unavailable states and TUN scope stay covered.
- `native-retention-smoke.json` records a run of the real production
  `SystemSampler` and native observer as an ordinary user. Initial state was
  loading, first available data took **2.554 s**, a three-second return reused
  available data on its first callback, and departure stopped after **20.050 s**.
  Returning after expiry first reported loading. Ten-second refresh subsequently
  remained available; explicit stop released collection.
- `NativeRetentionSmoke.swift` retains the standalone smoke driver. It links the
  built FtopCore/FtopSensors/CFtopSys debug objects with the ordinary bundled
  helper beside the executable. It retains no process names, PIDs or addresses,
  creates no extra network traffic, and changes no DNS, proxy or routing settings.
  Native timing is an observation on this Mac, not a latency guarantee.

## Visual checks and package

- Regenerated **181 native PNG references** in `references/`, including 24 new
  loading cases (two network sorts × single/wide/strip × two languages × two
  appearances) and four idle cards. All 28 new cases and representative existing
  normal/failure/size cases were viewed. No loading-text clipping or overlap was
  found. README media were regenerated with `scripts/readme-media.sh`.
- The isolated release preview was physically dragged through large two-column,
  tall/narrow, wide/thin, regular no-list and single-column five-row layouts.
  Cold download visibly displayed “数据读取中” below basic information, then
  replaced it with rates. Small forms keep their existing priority degradation.
  This complements the reference and fit sweeps; it is not an exhaustive live
  drag of every pixel size. The final ten-second arithmetic fix has no UI change
  and was verified against final production objects by the native smoke above.
- Rebuilt `build/Ftop.app`, version 0.2.6, local build 12. Deep strict signature
  verification and plist lint passed. No installation, remote push or release.
  Only the owned isolated preview and its helper were stopped after validation;
  installed copies, user configuration and system network settings were retained.

## Resource observation

`performance.json` holds five three-second samples from `scripts/perf.sh` with
the visible five-row download panel at one-second refresh, including its helper.
Combined CPU was **1.3–2.4% of one core**, mean **1.8%**, with approximately
**43.4–43.5 MiB** summed `top MEM`. The under-1% CPU reference target remains
unmet. This short background-active observation is not a controlled before/after
comparison, RSS measurement or worst-case bound. Hidden-window cost was not
measured in this pass; immediate suspension is covered by lifecycle tests.
