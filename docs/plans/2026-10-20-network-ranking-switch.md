# Network ranking loading and warm switching

Status: local implementation and validation complete on 2026-10-20. No install
or publication is part of this change.

## Requirements

- Show “数据读取中” (English: “Reading data…”) in the existing process-list
  space while the first network rate is being collected. Keep real failures,
  expired readings and missing usage distinct from loading and measured zero.
- After leaving download/upload for CPU/memory, continue collecting for a fixed
  20 seconds. Returning to either network mode reuses the observer and current
  rates. CPU/memory switches and unrelated settings changes do not extend the
  deadline. Hiding the panel or disabling Processes stops collection immediately.
- Remove the idle process-card instruction to switch to a network ranking.
  Preserve the TCP/UDP and proxy/TUN attribution details.

## Implementation

- Add an explicit network loading state and reuse reserved list-row geometry in
  the native Scene. Keep badge drawing, typography and layout measurement
  unchanged. Cold entry and immediate source stops clear only network display
  state; warm switches retain current network rows and ranking stabilization.
- Keep the native observer start idempotent. A queue-confined demand controller
  owns one monotonic 20-second deadline, invalidates canceled callbacks with a
  token, and checks for an overdue deadline before reusing an observer. Expiry
  publishes collection-off state without waiting for the next hardware tick.
- Preserve App callback generations, stop immediately for hidden/menu-bar-only
  operation and disabled Processes, and reset the source after wake. Discard old
  UI rows on a cold return before rendering the next sample.
- Support the configured 10-second hardware interval by dividing cumulative
  source deltas by their actual finite, positive elapsed time. Retain the separate
  six-second freshness check on the latest native frame, process identity checks,
  bounded batches and source-removal accounting.
- Suppress only the idle instruction in presentation; keep actual diagnostic
  reasons and the existing socket/proxy/TUN scope description.

## Completed validation

- `scripts/check.sh` passed, including both runs of the 273-test suite.
- Deterministic lifecycle tests cover 19.999/20-second expiry, warm returns,
  CPU/memory and interval restarts, early and canceled callbacks, overdue return,
  immediate hide/module stop, and CLI collection without a grace period.
- A real native lifecycle check verified warm observer reuse and shutdown after
  the 20-second grace period. The 10-second interval regression verifies rates
  across existing, new and removed sources without repeating their bytes.
- Native reference images were regenerated and inspected, including loading,
  idle cards, both languages and appearances. The real panel was dragged through
  small, narrow, thin and large sizes; loading uses the existing reserved space.

Evidence is retained under
[`docs/evidence/2026-10-20-network-ranking-switch/`](../evidence/2026-10-20-network-ranking-switch/).
