# Bounded event-driven Wi-Fi DNS reassertion

Owner request: maintain the selected Wi-Fi DNS rule after external modifications,
yielding only after more than five changes in a short interval. This supersedes
the earlier single-external-change stop behavior. It does not alter network
authorization or introduce a privileged helper.

> Authorization renewal described below is historical. The 2026-11-06 request
> adds one on-demand native prompt on a confirmed no-write authorization denial;
> cancellation and uncertain writes still stop. See `2026-11-06-dns-authorization-renewal.md`.

## Decisions

- Interpret the short interval as a rolling 60 seconds and "more than five" as
  the sixth observed override. The first five are reasserted from freshly read
  immutable service/DNS baselines. Both exact and default rules use this policy.
- Count only observed semantic address/key changes away from the selected rule
  on the same connection. Initial inherited settings, duplicate notifications,
  metadata-only changes, already matching values and verified own writes do not
  consume budget. Own writes also must not clear past override times.
- Entries exactly 60 seconds old expire. Clock input includes system sleep, is monotonic and injected
  from the coordinator; Core never reads a system clock. Store at most six times.
- The sixth change leaves the external value untouched and pauses that connection
  indefinitely, even after 60 seconds pass. Reconnecting to a new identifiable
  association, confirmed disconnect, disabling or explicitly saving rules resets
  the budget. An unknown/redacted SSID does not reset it.
- Existing native notifications/coalescing drive all work; there is no polling,
  retry timer, second concurrent evaluator or per-sample path. Several writes
  coalesced into one observation cannot be counted as separate external overrides.
- Only the rule runtime opts out of the transaction's known-writer process-presence
  veto, because the bounded policy now arbitrates external writers. All immutable
  baseline, SSID/interface, lock, stage/commit/apply and readback checks remain.
  Other kernel callers retain the default veto. Preserve every non-address field.
- Authorization expiry/cancellation, invalid target and failed/uncertain writes
  remain explicit stops. A race inside a transaction is not permission to write
  against a stale baseline. This change does not promise long-lived authorization;
  the diagnosed macOS credential expiry still requires explicit renewal.
- Keep the editor layout and styles; update the paused message to describe the
  sixth-change threshold and reconnect/Save & Apply recovery. Build 17 distinguishes
  this local artifact from the earlier 0.2.6 build 16.

## Validation

Use pure Core policies with simulated timestamps, injected coordinator monitors,
readers and clocks, and the existing fake transaction backend. Cover first through
sixth overrides, window expiry/boundary, duplicate notifications, own writes,
metadata-only changes, address equivalence/order, explicit reset/new connections,
known competing writer presence, fresh targets and original transaction failures.
Run strict Swift format and `scripts/check.sh`. Export and inspect the changed
blocked state in both languages/appearances/widths and check existing window fits.
Build/sign-verify a local app only; do not install, launch, publish or write real DNS.
