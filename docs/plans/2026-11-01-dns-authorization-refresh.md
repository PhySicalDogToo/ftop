# Refresh Wi-Fi DNS intent after authorization

> The immediate stop on one external edit below is historical: the 2026-11-04
> bounded-reassertion request supersedes that part only. Authorization, fresh-read
> boundaries and failed/uncertain-write protections remain unchanged. See
> `docs/plans/2026-11-04-dns-reassertion.md`.
> The 2026-11-06 request additionally renews an expired right with one native prompt
> after confirmed no-write denial; an actual cancellation/failure still suppresses
> repeat prompts. See `docs/plans/2026-11-06-dns-authorization-renewal.md`.

## Problem and scope

An administrator sheet can outlive the Wi-Fi association it was opened for.
`evaluate()` previously read and matched first, awaited authorization, then sent
that old target to the safe writer. The transaction rejected changes, but the
coordinator exposed a stopped state. Before transaction entry, a temporarily
missing physical service was also presented as an error. Passive panel refresh
replaced SSID/DNS without replacing the preceding rule and execution status.

## Implementation

- A bounded, nonrecursive two-pass evaluation treats its first policy decision as
  tentative. Authorization success discards that policy copy, SSID, service,
  connection ID, DNS and match. The second pass reads and matches everything again.
- Explicit Save & Apply still prepares a native session. Event-time evaluation
  acquires one only when a write is needed. A fresh matching configuration is
  marked active without entering the write transaction.
- Existing location authorization callbacks feed the existing coalesced queue.
  There is still one location delegate and one evaluation at a time; busy events
  request one subsequent evaluation rather than starting concurrent writes.
- Pre-transaction `noPhysicalService` is waiting, without a failed-write block.
  The Wi-Fi monitor reuses the existing dynamic-store observer for raw service,
  IP, route, DNS/setup and link hints. These are not filtered by unchanged DNS
  values and never poll or bypass the pure policy's external-edit/write blocks.
- SSID, match/default selection, DNS and phase are published together. Enabled
  panel refresh is a full evaluation; passive reads cannot overwrite its result.
- Authorization cancellation/denial clears the native session and requires an
  explicit Save & Apply before prompting again. Epochs, task cancellation and the
  synchronous mutation latch prevent abandoned authorization from resuming writes.
- No change to `DNSSettings`, the native lock/commit/apply/readback transaction,
  complete-field baselines, or the Core rule policy was necessary.

## Validation and limits

Coordinator runtime, monitor, store and reader dependencies are injected in a new
App test target. Authorization is a controlled continuation, reads come from a
locked fixture, and all writes are recorded mocks. Runtime transaction tests still
exercise the original fake write backend and cancellation checkpoints.

The readiness recovery has no time limit: a later native event can start a new
check, even if SSID and effective DNS remain the same. It depends on successful
notification registration and delivery. If registration fails or macOS emits no
subsequent hint, there is no polling fallback; the state remains waiting until a
Wi-Fi/wake event or manual recheck. No claim of guaranteed recovery under missing
system notifications is made.

No real permission/authorization, hotspot/company-network switch, DNS write,
installation or publication is part of automated validation. Reference images use
sample state only. Results are recorded in
`docs/evidence/2026-11-01-dns-authorization-refresh/`.
