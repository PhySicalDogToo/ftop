# Per-process upload and download ranking

Owner request: validate the cost of persistent nettop sampling and traffic
attribution with Clash TUN before adding upload/download modes to the existing
process list. Keep the native glyph style and verify every window form.

Status: local implementation complete and validated on 2026-10-20; final
application cost is recorded in the evidence directory. Not installed or published.

## Data and lifecycle

- Keep CPU and memory sampling and the privileged helper unchanged. Network
  candidates come from a separate, unprivileged native NetworkStatistics
  observer, never from the CPU/memory Top96 subset. Private declarations and
  dynamic symbol loading remain in CFtopSys.
- nettop was tested first. EOF on inherited stdin caused over 100% CPU; pipe
  and PTY experiments changed both output and cost. The working PTY setup used
  about 1.3% CPU including its wrapper. A native 12-second prototype produced
  six completed queries at about 0.6% CPU including startup, with about 5 MiB
  peak RSS. Use the native route and measure the final app independently.
- Start collection only for a selected network ranking while the process list
  is enabled and the panel is visible. Stop it for CPU/memory, menu-bar-only
  sampling and shutdown. Hardware sampling never waits for a native query.
- Discard the initial baseline. Compute rates from byte deltas and monotonic
  elapsed time. Publish only complete bounded batches; an interrupted, stale or
  malformed stream must not keep presenting old readings as current.
- Group all observed network processes into applications before limiting the
  ranking. Preserve explicit availability for usage figures of network-only
  candidates and for failed network collection. Missing is never zero.

## Display

- One list, four modes: processor, memory, download, upload. The wide header
  reuses the native CPU, memory and up/down glyphs. More offers the same choice
  for small windows. All forms that show a process follow the selected mode.
- Reserve the widest supported rate/units independently of current readings.
  Keep current figures and separate ranking stabilization for each metric.
- Network activity belongs to the process reported by macOS. Never reassign a
  proxy's bytes to another app or use physical-interface totals as the
  denominator for process activity. Explain proxy/TUN limits in details.

## Validation

- Record bounded nettop CPU/RSS measurements, genuine stream fixtures and
  current Clash runtime/TUN observations without retaining credentials or
  remote connection details. Do not modify DNS, proxy settings or profiles.
- Test framing, first baseline, rates, process identity, partial/stale batches,
  availability, grouping and independent ranking candidates.
- Exercise every mode with wide/narrow/strip candidates, unavailable readings,
  extreme rates, long names, both languages and appearances; regenerate and
  inspect references and README media; drag an isolated real preview through
  small, thin and large sizes.
- Run scripts/check.sh; package and validate build/Ftop.app. Measure the panel,
  helper and additional sampler together. Do not install or publish.
