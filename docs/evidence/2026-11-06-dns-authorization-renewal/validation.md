# On-demand DNS authorization renewal — 2026-11-06

## Behavior and safety

The retained native backend is a session object, not proof that its credential is
still valid. Transactions continue checking the native right without interaction.
When `apply` returns permissionDenied with confirmed unchanged persistence, the
coordinator restores its pre-attempt policy, releases the session and requests one
native authorization outside the transaction. The second of at most two passes
authorizes first, then rereads SSID, physical service, connection identity and DNS
and rematches exact/default rules. A fresh matching DNS skips mutation entirely.

Cancellation, any failure while establishing the authorized session (including
busy/unavailable), or another permission denial after that grant suppresses
prompts until explicit Save & Apply. Duplicate callbacks are coalesced; shutdown
and task cancellation still invalidate the synchronous mutation checkpoints.
Saved/unknown results and failures after a returned write result cannot enter
renewal/retry. The original lock/stage/commit/apply/full verification kernel and
all non-address DNS-field preservation are unchanged.

Renewal does not reset or double-count the first-five-in-60-seconds contention
budget. A sixth observed override still pauses without an authorization prompt.
Already matching configurations do not ask for credential refresh. No extra timer,
polling, observer, helper, proxy client integration or hardware-sample work is added.

## Validation

- Strict Swift formatting completed. `git diff --check` passed.
- `scripts/check.sh` passed on the final source: strict format lint, a
  warnings-as-errors build and two complete 263-test runs. The first run reported
  88.029 seconds; the script's silent second run returned success. No Swift source
  changes followed this final gate.
- Ten new coordinator regressions cover retained-but-expired sessions, fresh
  network/rule/service/DNS after renewal, matching-config no-ops, delayed service
  readiness, cancellation/denial/busy/unavailable suppression and explicit save,
  immediate repeat denial, saved/unknown results, post-write read denial, shutdown
  and preserved contention history. Existing initial-authorization/task-cancel
  regressions remain. The runtime expiry regression also verifies explicit
  session renewal and a later verified write, without a prompt inside the writer.
- `FTOP_DNS_RULES_RENDER_DIR=docs/evidence/2026-11-06-dns-authorization-renewal/references
  swift test --filter DNSWiFiRulesRenderTests` passed both tests and generated 44
  native offscreen images. All status fit checks cover 380/520-point widths;
  authorization text additionally has measured-height assertions. Inspected the
  Chinese-dark and English-light compact authorization references and the
  Chinese-light and English-dark wide references; status text is fully visible.
- `FTOP_SIGN_IDENTITY= scripts/bundle.sh` built local `0.2.6 (18)` successfully.
  `codesign --verify --deep --strict build/Ftop.app` passed; the bundle's version
  was reread as 18. Previous build 17 is retained at
  `build/Ftop-before-dns-authorization-renewal-20261106.app`. Neither app was launched.

## Real-system limits

- No native authorization dialog, credential timeout, physical Wi-Fi switch or
  actual DNS write is exercised by the tests. Coordinator tests use controlled
  continuations/readers/monitors; runtime tests use only an in-memory backend.
- macOS still controls authorization lifetime and whether a dialog is necessary.
  This does not create a permanent grant; a later required write can ask again.
- Post-authorization service readiness can recover on later native hints, without
  a deadline. Missing notification registration/delivery still has no polling
  fallback; a later network/wake event or manual recheck is required.
- Only status text changes. Main monitor Scene, adaptive layouts, sensors and
  process/network ranking are unchanged. Live resizing and performance sampling
  are not repeated; the production app is not launched during validation.
- The generated app remains local. No installation, publication, Git push or
  replacement of an installed running app is authorized or performed.
