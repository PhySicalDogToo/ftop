# Bounded DNS reassertion validation — 2026-11-04

## Behavior

The owner replaced the immediate external-edit stop with rule reassertion. The
short period is a rolling 60 seconds: restore the rule after the first five
observed address/key deviations; the sixth leaves the external DNS untouched and
blocks that connection until a new identifiable association or explicit save.
Clock input is injected and uses ContinuousClock in production, including sleep
and excluding wall-clock adjustments. Expiration is checked only on events.

DNSWiFiRulePolicy compares ordered semantic addresses and presence of the manual
key. Fingerprint-only metadata changes, already matching values and duplicates
do not count. recordApplied adopts the verified result without clearing the
override times. The first inherited configuration on a new connection is not an
external override. The array is bounded at six timestamps.

DNSWiFiRulesCoordinator still reads a fresh service/DNS baseline for each attempt
and discards tentative inputs after authorization. Only the runtime's rule path
sets permitCompetingWriter: true, allowing the new bounded policy to arbitrate
instead of rejecting a known writer's process presence. One-shot transaction
callers retain the old default veto. All target/SSID/baseline/lock/stage/commit/
apply/readback checks and complete non-address field preservation remain intact.

## Checks

- Strict Swift formatting completed; git diff --check passed.
- Focused fake-backend regression: 73 tests passed, followed by the extra
  competing-writer stale-baseline case in a 13-test runtime/render run.
- Final coordinator/Core monotonic-clock follow-up: 22 tests passed.
- scripts/check.sh passed strict formatting, build and two complete 253-test runs.
- Final strict format / warnings-as-errors build was also run after the clock
  follow-up. No source changes followed that check.
- scripts/bundle.sh built local 0.2.6 (17). The ad-hoc bundle passed deep/strict
  signature verification. The previous generated app is retained at
  build/Ftop-before-dns-reassertion-20261104.app.

New coverage exercises first through sixth overrides, sticky pause, 60-second
boundary/expiration, duplicate callbacks, own writes, empty-key reinsertion,
IPv6 equivalence/duplicates/order, metadata-only edits, fresh write targets,
known writer presence, stale-baseline rejection, sparse changes, reconnection
and explicit-save reset. Existing authorization/cancellation and failed/uncertain
write tests remain in the full gate. Every DNS write in these cases is fake.

## UI

FTOP_DNS_RULES_RENDER_DIR=docs/evidence/2026-11-04-dns-reassertion/references
swift test --filter DNSWiFiRulesRenderTests produced 40 offscreen native references
in English/Chinese, dark/light, compact/wide forms. Inspected the changed paused
message at both 380 and 520 points and in both languages/appearances. Text-height
assertions cover waiting and paused states; all editor-state fit checks passed.
No editor geometry, monitor Scene or adaptive panel layout changed. Live panel
dragging and performance measurement were not repeated; the production bundle
was never launched by this task.

## Limits

- This is a contention threshold, not evidence of another program's identity or
  intent. Several external writes coalesced before one read count as one observed
  deviation. It is driven by existing native notifications, with no polling.
- The diagnosed native administrator credential expiry is unchanged. Expired or
  cancelled authorization still requires explicit renewal; this change cannot
  promise unattended writes after authorization expires.
- Native transaction failures, unknown persistence, invalid targets and races
  inside the transaction still stop immediately, even before the sixth deviation.
  Reassertion never authorizes reuse of a stale baseline or unverified overwrite.
- No real DNS, permission dialog, physical network switch, helper installation,
  installed app replacement, production app launch, release or Git push occurred.
