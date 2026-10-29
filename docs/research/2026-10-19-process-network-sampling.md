# Process network sampling: source decision and independent review

Updated: 2026-10-20. Status: local implementation validated with local tests and
visual checks; not installed, published, or released. This record covers the
sampling route and its limits. The final validation record after the latest
provider-cache optimization and the final application performance measurements
will be appended separately; no final application cost is claimed here.

## Decision

Use an in-process NetworkStatistics observer for the download and upload process
rankings. Keep all private declarations in `CFtopSys`, with a Swift provider in
`FtopSensors`. Do not start a persistent `nettop` child in the application and do
not extend the setuid helper's arguments, environment handling, or file access.

The reason is a combination of measured cost, integration, and failure behavior.
The first nonterminal `nettop` measurements exceeded one CPU core. Follow-up
measurements showed that this depends strongly on standard-input/output setup:
a PTY reduced the combined collector cost to about 1.31% of one core. Therefore
the original result is not evidence that the underlying native counters require
130% CPU. The native route avoids the terminal dependency, child lifetime, CSV
framing, and wrapper process, and has a lower preliminary measured cost. Full
application measurements are a separate requirement.

## Primary source basis

Apple's [XNU `bsd/net/ntstat.h`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/ntstat.h)
defines byte counters, source events, TCP/UDP descriptors with PID and unique
process identifiers, and distinct kernel and userland providers. These definitions
support the counter and identity model; they do not establish complete coverage of
every provider or promise a stable public framework API. Reviewed on 2026-10-19.

The installed SDK's text stub was also inspected:

`/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk/System/Library/PrivateFrameworks/NetworkStatistics.framework/Versions/A/NetworkStatistics.tbd`

It exports manager creation/destruction, TCP/UDP registration, description/count
queries, source count/description/removal blocks, and the PID, UPID, process-name,
received-byte, and sent-byte keys used by the implementation. A text stub proves
symbol export names for that SDK, not their availability or exact behavior on
every operating-system release. Production resolves the required symbols at
runtime and reports unavailable when they cannot be used. No third-party source
implementation or code fragment was used as the basis of this decision.

## Measurements and what they establish

CPU percentages below are relative to **one core**, calculated from process CPU
time divided by wall time. They include startup and shutdown where stated; these
are short local experiments, not comparable production benchmarks under a fixed
traffic load.

| Route and setup | Recorded observation | Evidence |
| --- | --- | --- |
| Persistent `nettop`, inherited nonterminal input, piped output, 2 s interval | Child 132.817%; wrapper 0.029%; combined 132.846%; 7 CSV frames in 20.080 s | [performance.json](../evidence/2026-10-19-process-network/performance.json) |
| Same setup, 1 s interval | Child 137.093%; combined 137.129%; 19 frames in 20.099 s | [performance.json](../evidence/2026-10-19-process-network/performance.json) |
| Nonterminal setup with `-c`, 2 s interval | Combined 138.884%; no parsed frames in 8.137 s | [performance-gentle.json](../evidence/2026-10-19-process-network/performance-gentle.json) |
| Input pipe kept open, 2 s interval | Child 1.571%; combined 1.632%; no parsed frames in 8.095 s | [performance-open-stdin.json](../evidence/2026-10-19-process-network/performance-open-stdin.json) |
| PTY for input and output, 2 s interval | Child 1.244%; wrapper 0.067%; combined **1.311%**; 7 frames in 12.194 s | [performance-pty.json](../evidence/2026-10-19-process-network/performance-pty.json) |
| Standalone native observer prototype, six queries at 2 s spacing | Approximately **0.58%**; maximum resident size 5,210,112 bytes; 617 sources and six completions | [native-prototype.json](../evidence/2026-10-19-process-network/native-prototype.json) |
| Production C observer in a standalone smoke harness | **0.655%**, approximately **0.66%**; 0.07 s user + 0.02 s system over 13.74 s; two create/copy/destroy cycles, each with three completed frames; RSS not measured | [native-smoke.json](../evidence/2026-10-19-process-network/native-smoke.json) |

The terminal-dependent behavior is an observation from these runs. The specific
internal cause of the nonterminal busy loop was not established. The low-cost
open-input run also produced no usable frames, so a low CPU figure alone does not
demonstrate a working collector. The complete harness and frame-counting method
are retained in [probe.py](../evidence/2026-10-19-process-network/probe.py).

The 0.58% prototype and 0.66% C-only result must not be presented as ftop's total
CPU cost, as the feature's final CPU increase, or as complete protocol coverage.
They exclude some or all Swift identity lookup, aggregation, rendering, and the
application's other sensors. They were sufficient to select a route for further
implementation and validation.

The production C smoke preceded the final conservative owner-change baseline
refinement. The successful download retry below was rebuilt against the final
production C source. Neither observation measures the latest Swift cache changes.

## Current meaning of a process rate

The observer registers TCP and UDP sources and computes differences between
completed observations. It reports socket activity attributed to a process, in
bytes per second. This can include local connections and proxy connections; it
is not a measurement of the physical network interface or an Internet-only total.
Other userland network providers may be unavailable through this route.

Under Clash TUN, traffic may appear under both the original application and the
proxy core. Adding process rows does not deduplicate those layers. Proxy activity
can also include unrelated background traffic. The display therefore gives
network rankings no share arc derived from the physical-interface total and
includes an attribution note in the card and unavailable-state detail.

First observations establish baselines rather than crediting a socket's entire
existing lifetime. For a newly observed source inside an interval, only its
increment after the recorded initial observation is counted. Sources without a
safe baseline are skipped without suppressing other measured sources of the same
process. First-observation bytes and very short-lived connections can be missed;
the figures are the observed activity, not an exhaustive accounting ledger.

The native attribution controls used the production C interface:

- The initial public HTTPS attempt timed out with curl 28, HTTP 0, and no response
  body. This is inconclusive for download attribution, not a successful zero-rate
  transfer. In the same control record, a local 2 MiB POST succeeded with HTTP 200;
  the original client had 1,899,504 observed transmitted bytes and 110 received
  bytes. The gap between body size and observed counters illustrates the baseline
  and observation-window limit. See
  [native-attribution.json](../evidence/2026-10-19-process-network/native-attribution.json).
- A bounded IPv4 retry using the final production C source succeeded with HTTP
  200 and a **2,097,152-byte response body (2 MiB)** in 23.405 s. The original
  client had **2,079,251 observed received bytes** and 24 sent bytes, with 14
  completed observer frames. This demonstrates download visibility for this
  client/run, without promising every body byte. Concurrent Clash traffic was
  5,092,637 received and 3,080,157 sent bytes; those values include background
  activity and were not merged, subtracted, or deduplicated. Changing address
  family and timeouts together does not establish the initial timeout's cause.
  See [native-download-retry.json](../evidence/2026-10-19-process-network/native-download-retry.json).

TUN remained enabled, saved DNS mode remained redir-host, and the runtime
configuration remained unchanged before and after these controls. No inference
of complete app/protocol coverage or exact proxy overhead follows from them.
Earlier `nettop` attribution evidence is retained separately in
[attribution.json](../evidence/2026-10-19-process-network/attribution.json) and must
not be treated as a native-collector result.

## Identity, candidate selection, and unavailable values

Network candidates are independent of the helper's CPU and memory top lists.
The complete observed candidate set is grouped into applications before either
network ranking takes its 96-entry limit. This avoids losing an application's
combined traffic because each helper process was below a CPU, memory, or network
prefix cutoff.

Counter continuity requires both the socket source ID and the process's PID plus
unique identifier. Live metadata lookup verifies the same process identity before
using a name or app path. A reused bare PID cannot inherit the former process's
traffic or cached CPU/memory figures. Network-only entries carry
`usageAvailable=false`; their CPU and memory placeholders are displayed as
unavailable. A stable app bundle can join the separately sampled application
usage summary, preserving the existing app aggregation convention.

`ProcessNetworkSample?` distinguishes an unknown rate from a measured zero.
`ProcessNetworkStatus` distinguishes a valid empty ranking from an unavailable
reader. Old JSON has no invented network reading: missing fields decode to nil,
empty network lists, and an unavailable status; old CPU/memory availability
defaults are preserved. The selected network ranking never falls back to CPU.
CPU, memory, download, and upload each have their own steady-order state; the row
figures remain current readings, not the ranking's internal levels.

## Lifecycle and independent review findings

Collection is enabled only while the panel is visible, the process module is
enabled, and a download or upload ranking is selected. CPU/memory-only selection,
menu-bar-only operation, a hidden process module, and stopped sampling do not keep
the native observer running. Configuration and visibility transitions invalidate
older queued application callbacks with a sampling generation.

The C observer owns a serial queue and two-second query timer. Hardware sampling
copies a completed snapshot with a nonblocking mutex attempt; it does not wait
for a query completion. A transient busy read can retain only a still-fresh
cached result. Six-second stale or incomplete-query limits, missing symbols,
invalid counters, and the 16,384-source bound produce an unavailable state rather
than a fabricated zero. A failed active provider tears down and waits 30 seconds
before attempting recreation; an explicit stop disables those retries.

Independent review identified and checked the following corrections:

- New or reset sockets no longer erase valid increments from the same process's
  other sources. Newly observed sources use only a safe in-window baseline.
- Removed sources keep their final counters until a completed frame has been
  copied and acknowledged. Retirement also checks that counters have not changed
  since that frame. Swift retains the removed baseline until actual absence, so
  late final increments neither subtract lifetime totals nor repeat them.
- Copied callback blocks retain a small owner object. Teardown marks it inactive
  before freeing larger buffers; late callbacks check that state and the slot's
  source ID. Copy and destruction are serialized by the Swift sampler's calling
  queue, while completed frame copying is protected by the snapshot lock.
- Bare PID joins cannot provide CPU or memory to network-only entries. Unknown
  rates do not retain old measured ranking levels, and a pointer hold preserves
  their existing row positions.
- Network rate presentation rejects nonfinite or negative values and bounds
  very large labels with an explicit overflow indication. The panel reserves the
  same figure width across all four sorts; changing a reading or sort does not
  change its natural size.
- The latest cache optimization decodes a native generation once while still
  checking native failure and freshness on every copy. Provider metadata is
  cleared on each generation and teardown. Repeated ticks verify the live unique
  process ID before reusing a name or app path, and a reused generation cannot
  change its completion timestamp to extend its lifetime. Names and paths may
  remain from the same approximately two-second frame; cached metadata does not
  keep an exited or reused PID on the list.

These findings are source review results, not a claim that every private API
ordering or operating-system version has been verified. No packet payload,
connection address, port, or DNS name crosses the C/Swift sampling boundary. The
collector does not alter DNS, Clash configuration, routing, or TUN state.

## Final integrated validation

The final generation-cache version passed `scripts/check.sh`: strict formatting,
a warnings-as-errors build and two complete passes of 249 tests. Thirteen sensor
provider tests include cache reuse, per-tick process liveness, identity reuse,
new-generation metadata refresh, fresh helper usage and timestamp-renewal
rejection. A final-C AddressSanitizer harness completed 20 rapid lifecycle cycles
without a report; leak detection was disabled. See
[native-asan.json](../evidence/2026-10-19-process-network/native-asan.json).

Generated 137 native reference pictures, reviewed the process/control forms in
both languages and appearances, and dragged an isolated real panel through
regular, large, tall/narrow, wide/thin and micro sizes. The native More menu
exposed all four modes and selected upload. The six-column optional-module
control fixed during reference review is covered by a bounds regression test.
The final release app passed deep strict code-signature verification and plist
validation, and its explicit `probe --network --json` returned finite,
nonnegative, independently sorted download/upload candidates. This is local
validation on the current Mac, not a compatibility claim for every OS version.

The final panel-plus-helper measurements, including CPU/memory baseline,
download, upload, and 0.5 s refresh with continuous loopback connection churn
are recorded in
[app-performance.json](../evidence/2026-10-19-process-network/app-performance.json).
Memory in that record is `top MEM`, not independently measured RSS. The C-only
figures above do not substitute for the full application measurement. Short
sequential runs have background activity and do not isolate the causal cache
benefit. See the evidence README for the measured ranges and remaining budget
limitation: the normal modes measured 1.0–1.5% of one core; the 0.5 s control
peaked at 12.8%, so the under-1% reference CPU target remains unmet. A reliable
real hidden-window cost measurement was not completed; its attempted sample is
excluded. Nothing was installed, published, or written to network settings by
this collector validation.
