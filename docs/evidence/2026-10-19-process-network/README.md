# Per-process network feasibility and production-interface evidence

All probes ran as the ordinary user, without sudo, installation, packet capture,
DNS-setting changes, Clash configuration writes, reloads, or TUN toggles. The
tool's restricted execution sandbox cannot create an NStat manager; hardware
probes therefore ran outside that sandbox. This is not evidence that the app
requires root. No secrets, real process identifiers/names, remote connection
addresses, DNS answers, or payloads are stored here.

## Decision and measurement scope

Use the native, dynamically loaded NetworkStatistics observer. It has a working
low-overhead path and avoids a terminal/CSV dependency. The private API may become
unavailable on another macOS version; the production implementation reports
unavailable and retries with a bounded delay. It does not expand the setuid
helper or request additional privileges.

CPU percentages are normalized to one logical core: `(user + system CPU seconds)
/ wall seconds * 100`. The nettop process is counted, not just its Python wrapper.
The nettop runs include process startup and shutdown. These are short local
measurements under existing background activity, not an idle-system benchmark.
Full Swift-provider/app performance is a separate validation.

## nettop is sensitive to its terminal/input environment

The command was a persistent `nettop -n -P -J bytes_in,bytes_out -x -L 0 -d -s N`.
`-n` disables name resolution; `-P` and `-J` omit connection details. The process
was terminated at the bounded end of each run. **Do not describe nettop as always
using 130% CPU:** the high values occurred with inherited input at EOF.

| Standard input/output | Interval | Window | nettop CPU | Peak RSS | CSV frames |
| --- | ---: | ---: | ---: | ---: | ---: |
| Inherited input at EOF, stdout pipe | 2 s | 20.08 s | 132.817% | 7.594 MiB | 7 |
| Inherited input at EOF, stdout pipe | 1 s | 20.099 s | 137.093% | 7.609 MiB | 19 |
| Same, with `-c` | 2 s | 8.137 s | 138.847% | 7.422 MiB | 0 |
| Open stdin pipe, stdout pipe | 2 s | 8.095 s | 1.571% | 5.969 MiB | 0 |
| Independent PTY for stdin/stdout | 2 s | 12.194 s | 1.244% | 6.922 MiB | 7 |

The wrapper added 0.029–0.067% CPU. An independent `ps` reading during the EOF +
`-c` run reported 138.1% CPU, 6,656 KiB RSS and 9.71 s accumulated CPU, confirming
that the high number was the child process, rather than unrelated Python child
work. The EOF result is consistent with a terminal/event-loop busy-spin, but the
exact nettop internal cause was not proved. Keeping only a pipe open did not
produce a completed CSV frame during its short observation window. A PTY worked,
but the selected native path was simpler and cheaper in the observed runs.

See `performance*.json`. `sample-sanitized.csv` preserves the real CSV header,
trailing empty fields, and measured counters from two adjacent PTY frames; process
names/PIDs and timestamps are synthetic. Repeated headers delimit batches. There
was no separate machine-total row. The first batch is a baseline even with `-d`;
it must not be presented as an instantaneous rate. Exited probe clients became
absent from later rows; an absent row is different from a present row with zero
bytes.

## Native production-interface smoke

`native-smoke.c` uses the production public C interface, including two observer
create/copy/destroy cycles. The run completed successfully in 13.74 s, with
0.07 s user + 0.02 s system CPU, approximately **0.655% of one core**. Each cycle
yielded three completed frames. Peak source counts were 397 and 412, with 1,161
and 1,176 live unique-process-ID matches across frames. No addresses or process
identifiers were printed. RSS was not measured in this run and is recorded as
null. See `native-smoke.json`; the earlier independent symbol prototype is
`native-prototype.json`.

The production observer has its own serial queue and two-second query timer. The
hardware sampler only tries to copy an already completed snapshot. Per-source
baselines avoid subtracting closed-socket lifetime counters from a process total.
New sources can contribute only increments observed after their first baseline
inside the current window. A change of PID/unique identity invalidates that
source's initial counters together. First observations and very short-lived
connections can therefore be missed. The final owner-change refinement happened
after the smoke and first control runs; the successful download retry below was
rebuilt against the final production C source.

## Existing Clash TUN attribution controls

Before/after local read-only API checks confirmed TUN enabled and saved DNS mode
`redir-host`; the runtime configuration hash remained unchanged. Both original
client and concurrent Clash activity were measured separately. Neither was
divided by physical-interface throughput, subtracted from the other, or silently
deduplicated. Existing background traffic makes the Clash column non-causal.

The first `nettop` control (`attribution.json`) transferred a 4 MiB local HTTP GET.
The original client received 4,194,420 socket bytes and the local server sent the
same count: the 4,194,304-byte body plus 116 HTTP-header bytes. The original client
later disappeared from subsequent frames. Curl's 256 KiB/s consumption limit does
not guarantee smooth kernel/socket delivery: buffering can produce larger
per-frame bursts, so body/time and a peak socket rate need not match.

A public HTTPS GET successfully downloaded 2 MiB in that control. nettop observed
2,105,788 received bytes and 543 sent bytes for the original client while TUN was
enabled. Concurrent Clash traffic was approximately 12 MB received, demonstrating
why it cannot be treated as this client's exact attributable overhead. This
proves visibility for this client/run, not complete attribution for every app,
delegated/userland network provider, proxy, or protocol.

`native-attribution.c` then exercised the **production C interface** through the
same per-source/process identity boundary (`native-attribution.json`):

- A second bounded public GET timed out while connecting after 5.006 s (curl 28,
  HTTP 0, zero response body). Its rate result is **inconclusive**, not a measured
  zero-speed success. The observer still completed four frames.
- A 2 MiB POST to a local loopback-only server succeeded with HTTP 200 in 9.134 s.
  The production C counters observed 1,899,504 transmitted bytes and 110 received
  bytes for the original client, with five live identity matches across six
  completed frames. This confirms original-process upload visibility, while also
  showing that first observations/window boundaries can omit bytes. No claim is
  made that all body bytes must be captured.
- Concurrent Clash transmitted 2,945,372 bytes during the local-only POST. That
  traffic was existing background activity, not causally attributed to the local
  request, and it was not subtracted or merged with the original client.

One explicitly authorized public retry then succeeded with IPv4, a 12-second
connection timeout and 35-second total timeout (`native-download-retry.json`).
It returned HTTP 200 and a 2,097,152-byte body in 23.405 s. The final production C
interface observed 2,079,251 received bytes and 24 sent bytes for the original
client, with 11 live identity matches and 14 completed frames. The counter does
not promise all body bytes: the initial observation/window boundary can omit
some bytes. Concurrent Clash received 5,092,637 and transmitted 3,080,157 bytes;
that column remains background-inclusive and was not deduplicated. Changing the
address family and timeout together does not establish the initial timeout's
cause. The local GET fallback was not needed and no further retries were made.

Total successful public response body across these probes was **4 MiB**
(2 MiB success + zero-byte failed attempt + 2 MiB successful retry). Public GETs
were limited to at most 2 MiB each, with no redirects and bounded
connection/total timeouts. The POST upload was local only. No external upload or
remote write was performed. TUN state and the runtime configuration hash stayed
unchanged in the retry as well.

## Reproduction

`probe.py performance --seconds 20` compares inherited stdin, 2 s then 1 s.
`--gentle`, `--keep-stdin`, and `--pty` are explicit standard-I/O variants;
`--intervals 2` restricts the run. `probe.py traffic` performs the earlier controls.
These commands create/update only this directory's sanitized evidence files.

Build `native-smoke.c` or `native-attribution.c` with the production
`Sources/CFtopSys/NetworkStatistics.c`, `-O2 -fblocks -framework CoreFoundation`
and `-I Sources/CFtopSys/include`, writing executables under `/private/tmp`.
`native-attribution.py` expects `/private/tmp/ftop-native-attribution`; it uses a
local read-only Clash API, keeps its credential in memory/stdin, and records only
the boolean TUN state plus sanitized counters. Re-running traffic controls uses
additional network data and must stay within the requested budget.
Its explicit `--retry-get` mode performs one bounded IPv4 public GET and, only on
failure, a local GET fallback; it has no persistent or automatic retry loop.

## Final local integration validation — 2026-10-20

The final version passed `scripts/check.sh`: strict formatting,
warnings-as-errors build, and two complete passes of **249 tests**. The network
provider suite has 13 tests, including the final generation-cache identity and
freshness regressions. `native-asan.json` records 20 final-C rapid
create/copy/destroy cycles with AddressSanitizer and no report; leak detection
was disabled. The separate completed-query smoke remains in `native-smoke.json`.

`build/Ftop.app` was rebuilt after the final cache change and passed deep strict
code-signature verification plus plist lint. Its read-only `probe --network
--json` produced 18 download and 18 upload candidates, positive rates in both
directions, finite/nonnegative figures, correctly sorted lists and explicitly
unknown usage for network-only candidates (`hardware-smoke.json`). Counts depend
on currently observed connections; 18 is not a fixed or complete process count.
The current private framework works on this Mac without root; other systems may
report unavailable.

Generated **137 native reference pictures**. Reviewed all 44 process/control
pictures across both languages and appearances plus ten existing size pictures;
rechecked the six-column controls after fixing a clipped Processes module.
Automated fit/geometry checks cover all four modes, missing and extreme values,
long names, lists, rich strips, cards and scale changes. An isolated native panel
was actually dragged through regular, large, tall/narrow, wide/thin and micro
forms. The native More menu exposed all four ranking options and selected upload.
The final data-only cache change did not change the approved layout or glyphs.
README media were regenerated. No installed app was replaced; the temporary
preview and its helper were stopped after validation.

### Full application cost and remaining limit

See `app-performance.json` for sanitized individual readings. Each row below is
five three-second `top` intervals after discarding its initial lifetime sample.
It includes the panel **and its direct helper**; the native observer runs inside
the panel. Memory is summed `top MEM` converted to approximate MiB, not a separate
RSS measurement. The test used the same regular saved panel form, about
332×505 pt and five process rows. Startup and an overlapping CLI probe were
excluded from the final baseline. The existing installed copy was not included
in these totals and was left alone.

| Final version / refresh | Combined CPU range, one core | Mean | Combined top MEM |
| --- | ---: | ---: | ---: |
| CPU ranking, 1 s | 0.3–0.7% | 0.52% | 32.3–32.3 MiB |
| Download ranking, 1 s | 1.0–1.5% | 1.24% | 39.3–39.3 MiB |
| Upload ranking, 1 s | 1.0–1.5% | 1.30% | 39.3–40.3 MiB |
| CPU ranking, 0.5 s; no added traffic | 1.0–2.6% | 1.86% | 38.5–39.5 MiB |
| Download ranking, 0.5 s; no added traffic | 1.4–12.8% | 5.78% | 41.5–51.5 MiB |
| Download ranking, 0.5 s; loopback churn | 1.5–12.2% | 5.66% | 41.3–51.3 MiB |

The normal 1 s network modes cost 1.0–1.5% of one core in these samples, above
the project's under-1% reference CPU target. Measured memory stayed below the
60 MB reference budget. **The CPU target is not met.** At 0.5 s, the network mode
also produced short 12.8% peaks without added test traffic. The loopback churn
run had 12.2% peaks; it cannot establish that churn caused them. Each churn run
completed 80 local-only requests carrying 5 MiB in 20 s; the final run's details
are in `app-performance.json`. No additional external traffic was needed.

Generation caching avoids repeated Swift row/name decoding and metadata reads,
while each hardware tick still checks freshness, failure, and live process
identity. Short sequential measurements under changing background activity do
not isolate its causal benefit or predict sustained worst-case usage. The 0.5 s
peaks remain a documented performance limitation; this record does not claim
that the prototype cost or reference budget describes the full app.

A reliable native-automation hidden-state cost measurement was **not completed**;
the attempted button activation did not establish that the window was hidden,
so that cost sample was excluded. Explicit provider stop/restart/failure and
stale callback invalidation are tested or source-reviewed, but that does not
replace a real hidden-state performance measurement.

During the resumed overnight session the final manual-DNS fingerprint differed
from its initial baseline; that observation does not establish its cause.
Controlled attribution probes have their own matching before/after checks, and
the final Clash runtime fingerprint still matched the initial one. This feature's
collector has no DNS, proxy, routing or TUN write path; the isolated preview never
authorized its separate DNS automation. No installation, publication, sudo or
network-settings change was performed by these validation commands.
