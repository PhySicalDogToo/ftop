# ftop build 12 performance review — 2026-10-21

> Historical build 12 assessment: Wi-Fi DNS automation and proxy cooperation were retired on 2026-10-28. Advice about profiling or optimizing automatic rules no longer applies to the current product.

## Assessment

There is useful optimization headroom. The existing hidden-window suspension is
working. Visible network rankings remain above the project's reference target
of less than 1% of one core. Prioritize avoiding redundant work, then experiment
with collection demand and cadence. No production source or installed application
was changed by this assessment. All suggested savings remain unmeasured until a
controlled implementation comparison is made.

## Version and method

- Tested the local latest `build/Ftop.app`, version 0.2.6, build 12. The installed
  `/Applications/Ftop.app` remains build 11. Its matching marketing version does
  not make it the same executable.
- Copied the final bundle into a separate temporary bundle identity and isolated
  home/configuration. Re-signing changes the executable signature, so compared
  all non-zerofill Mach-O section contents with the final bundle after signing;
  they match. `metrics.json` retains the original full binary SHA-256 and common
  section digest. No rebuild, installation, grant, updater or network write.
- Apple M4, 10 logical CPUs, 16 GiB RAM, macOS 15.6.1. Motion and the CPU menu bar
  were enabled for visible tests; all normal modules, including read-only DNS,
  were shown. Automatic DNS rules were disabled in the isolated home.
- The main matrix used an observed single-column three-row layout, approximately
  349 x 383 pt. Large and micro cases record their own dimensions. Screenshots
  were used to verify state; no actual-process screenshots are retained here.
- Used `scripts/perf.sh <verified PID>`: five three-second windows per phase,
  discarding the initial lifetime CPU sample. Every one of the **65 windows**
  contains the panel and the same direct helper. Main-matrix phases also checked
  the helper identity before and after each run. Raw per-window readings, role
  inclusion, configuration and summaries are in `metrics.json` without PIDs.
- This was a busy user environment: system CPU in observed panel captures was
  approximately 37–80%, with roughly 11 GiB swap already used. User processes
  were not stopped. No artificial traffic was generated. Sequential runs are
  useful screening, not an idle baseline, stable workload, worst-case bound,
  regression against yesterday or proof of a fixed reduction percentage.

## Observations

CPU columns are percentages of **one core**, including the helper. Min/max are
three-second window averages, not instantaneous peaks. Memory is approximate
summed `top MEM` in MiB; shared pages may overlap. It is not independently measured
RSS, leak evidence, WindowServer/GPU cost or battery consumption.

| Phase | Mean CPU % | Window CPU range % | top MEM MiB |
|---|---:|---:|---:|
| cpu_1s | 1.28 | 0.7–2.4 | 31.4–32.4 |
| memory_1s | 1.16 | 0.9–1.4 | 31.4–32.4 |
| download_1s | 2.96 | 1.8–4.2 | 39.4–41.5 |
| upload_1s | 2.38 | 1.8–3.4 | 41.5–42.5 |
| download_2s | 1.78 | 0.9–2.3 | 42.5–43.5 |
| download_half_second | 3.5 | 2.2–5.4 | 43.5–44.6 |
| download_1s_repeat | 2.72 | 2.1–3.7 | 44.6–44.6 |
| cpu_grace | 2.28 | 2.0–2.5 | 42.6–43.6 |
| cpu_after_grace | 1.18 | 0.8–1.7 | 39.6–39.6 |
| download_large_1s | 2.58 | 2.0–3.4 | 51.6–51.6 |
| download_micro_1s | 2.38 | 1.9–3.1 | 42.6–43.6 |
| hidden_menu_bar | 0.16 | 0.1–0.3 | 46.6–46.6 |
| hidden_no_menu_bar | 0.08 | 0.0–0.4 | 44.6–44.6 |

- Two one-second download runs averaged 2.96% and 2.72%; two-second refresh
  averaged 1.78%. Half-second refresh averaged 3.50%, with a largest three-second
  window of 5.4%. This supports testing a lower-cadence option, without claiming
  a guaranteed reduction. The older implementation's 12.8% sample is not a
  result for this build.
- Early CPU-after-network grace averaged 2.28%; the later stopped phase averaged
  1.18%. The first phase fits inside the 20-second lease; the later one begins
  more than 25 seconds after departure. This is not a new exact-deadline test.
- The micro layout showed only badges and no process figures but still averaged
  2.38%. Source review confirms collection demand depends on configured module
  visibility and sort, not whether the current layout actually uses processes.
- Large-window CPU overlaps the regular-window range; these runs do not isolate
  a size effect. Its memory sample was higher, consistent with retained image
  surfaces and caches, but allocations were not independently attributed.
- The native control panel's Hide action was followed by CUA reporting
  `noWindowsAvailable`; no app query reactivated it during hidden measurements.
  Hidden with the CPU menu bar averaged 0.16%; with the menu bar disabled it
  averaged 0.08% (including one 0.4% window). Background DNS observation and
  deferred tasks still exist. Hidden state retains UI caches and an idle helper.
- Two separate five-second `sample` captures at requested 1 ms intervals exposed
  the expected SceneBuilder, native query callbacks, IOReport and network merge
  paths. `stack-paths.txt` retains selected sanitized symbols. Waiting threads
  are included: stack occurrence is **not** CPU-time share. Panel-only physical
  footprint in these captures was 35.9M for CPU mode and 42.6M for download mode;
  this is a separate metric and timing from the table.

## Prioritized optimization candidates

### 1. Separate static dimensions from live Scene construction

`Sources/FtopUI/SceneBuilder.swift:796–805` builds every module to get its natural
width and then builds it again for display. Stretching CPU height can cause
another CPU module build at line 809. `processModule` at lines 687–720 constructs
indexes, four formatted metrics, member data and the card payload during both
passes. Both build paths appeared in the short stack captures.

Cache dimension-only metrics or expose a pure measurement path keyed by machine,
layout candidate, scale, language and relevant module/settings inputs. Build the
live Scene once. Preserve the current widest-value geometry and resize behavior.
This avoids work without changing freshness or appearance. It does not imply a
50% reduction in total CPU: drawing, sensors and native callbacks remain.

Validation: existing fit sweep and regenerated references, every language and
appearance, machine/module/scale changes; measure regular and many-row windows
at 0.5 and 1 seconds before and after.

### 2. Reuse aggregated network results for an unchanged generation

`Sources/FtopSensors/ProcessNetworkProvider.swift:125` copies a completed C frame
on every hardware tick. Swift decode is already cached at lines 135–140, but
lines 277–310 still validate/process identities, construct entries, fold and sort
both directions and attach network data to CPU/memory lists. Native frames update
approximately every two seconds (`NetworkStatistics.c:234`). At 0.5-second UI
refresh, the same generation can therefore undergo this work about four times.

Cache the folded network component by generation and the validated identity set;
attach it to the current usage sample. Keep every-tick failure, freshness and
PID/UPID checks, and rebuild when liveness/ownership changes. Do not cache the
whole ProcessList, which would stale CPU/memory. A companion C API can skip memcpy
for an unchanged generation while preserving freshness and tombstone acknowledgement
semantics (`NetworkStatistics.c:258–274`).

Avoiding three of four aggregation passes could remove up to about 75% of that
repeated segment, **not 75% of total CPU**. Its actual share is unmeasured.
Validation: existing provider identity/liveness/failure/ten-second tests, new
cache invalidation cases, cold/warm return, and identical rate/rank output.

### 3. Base process collection demand on the information the layout uses

`Sources/FtopApp/main.swift:424–427` checks configuration alone. Micro/corner and
plain strips may contain no process information while still running the helper
and native observer. Use explicit layout demand. Include rich strips and an open
process card, which can need process data despite having no conventional list.
Keep interface-level network figures independent of per-process collection.

Reuse the existing fixed 20-second return window for transient resizing so quick
expansion keeps warm data. Expired expansion must show loading and never stale
rows. Do not restart collectors on every resize event. This has concrete evidence
of avoidable work in micro mode, but its savings require an on/off comparison.

### 4. Experiment with independent cadences and a lower-cadence option

The helper is requested every other hardware tick (`SystemSampler.swift:90–91`),
while CPU/GPU temperature is sampled every fifth tick (`Providers.swift:77,287`).
Changing UI refresh changes these workloads too. Native queries continue every
two seconds even for ten-second panel refresh. Source queries also scan fixed
16,384-slot arrays and request both descriptions and counts.

Use elapsed-time budgets for slow-changing readings and consider a user-visible
lower-cadence preset. The two-second observation is promising, but slower values
are a product tradeoff. Any native cadence change must preserve the six-second
frame freshness rule and correct owner changes. Do not bypass descriptions,
identity validation or TUN attribution to gain speed. Keep the requested 20-second
return behavior.

### Secondary opportunities

- Coalesce identical configuration application and watcher tasks:
  `FtopApp/main.swift:526–528,636–675`; Config already has Equatable. This mainly
  reduces switching bursts, not sustained idle cost.
- Cache the open card's geometry and bounded truncation results:
  `FtopUI/ProcessRows.swift:432,526–534` and `Scene.swift:280`. Measure with a card
  actually open or long names before spending effort.
- Grow native/Swift buffers with observed connection counts, retaining the hard
  16,384 cap. Fixed source/frame/Swift capacities represent about 6.5 MiB of
  allocated capacity, not an established resident saving. Current memory results
  make this lower priority than CPU work; asynchronous ownership increases risk.
- If automatic Wi-Fi DNS rules are used, separately profile their 20-second
  validation cycle (`DNSAutomationCoordinator.swift:172`). It includes process
  detection, configuration hashing and local Clash verification. An event-driven
  invalidation cache may reduce redundant validation, but every real DNS write
  must retain fresh safety/cooperation checks. This path was deliberately not
  enabled here, so these measurements do not represent its additional cost.

## Preserve and verify

Keep Core Animation, bounded animations, dirty rectangles, double IOSurfaces,
font/icon caches and immediate hidden-window collector suspension. There is no
measured reason to sacrifice sharpness or remove the existing motion. The display
link is only active for the short window-snap animation, not continuously.

For a follow-up implementation, profile section durations/allocations, then use
interleaved A/B/A runs under the same layout, connection load and refresh rate.
Repeat important cases over longer windows, including busy and quiet conditions.
Measure main app plus helper, wakeups and compositor/power separately. Keep the
less-than-1%-of-one-core and 60 MB reference budgets as goals, not promised results.
Apple's [performance workflow](https://developer.apple.com/documentation/xcode/improving-your-app-s-performance/)
and [timer guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)
support profiling, event-driven work and efficient timer scheduling; the current
code already uses leeway, so adding timer tolerance is not a new fix by itself.

No implementation changed, so this review did not rebuild or rerun the full gate,
render suite, ASan or prior TUN traffic attribution experiment. The prior build's
273-test gate remains historical evidence. This review adds performance and
read-only source evidence; no new correctness pass is claimed. Owned preview,
helper and diagnostic log reader were stopped afterward. Installed copies and
user/system network configuration were not changed.
