# On-demand native DNS authorization renewal

Owner request: actively ask for administrator authorization when a DNS rule write
needs renewed credentials, rather than requiring a second Save & Apply.

## Decisions and implementation

- Keep native transactions noninteractive. An existing backend only proves session
  presence; its right can expire. When a transaction returns `permissionDenied`
  with confirmed `unchanged` persistence, the coordinator discards that attempted
  policy decision, releases the old session and requests native authorization.
- One evaluation has at most two passes and one interactive authorization attempt.
  Both initial authorization and renewal happen before the second pass's reads.
  After success, reread Wi-Fi/SSID, physical service, connection identity and the
  complete DNS baseline, then rematch exact/default rules. No old target is reused.
- A fresh matching configuration is active without a write. A temporarily absent
  physical service waits for the existing native readiness hint, without polling.
- Cancellation/authorization failure, or another denial immediately after a new
  grant, suppresses prompts until explicit Save & Apply. Coalesced duplicate events
  cannot start concurrent sheets. This includes busy/unavailable failures while
  establishing the authorized session. Shutdown/task cancellation cannot resume writes.
- Saved/unknown transaction results and failures after a returned write result
  never enter renewal/retry. Original immutable
  baselines, native lock/stage/commit/apply/full readback, cancellation and conflict
  protection remain. No helper, shell, periodic prompt or proxy integration.
- Renewal neither resets nor double-counts the existing first-five-in-60-seconds
  external-override budget. The sixth override remains paused without asking for
  authorization. An already matching DNS configuration never prompts merely to
  refresh credentials.
- Keep panel geometry, styles and hardware/process sampling unchanged. Replace
  only the authorization-in-progress message; export and inspect its compact and
  wide states. Local app build 18 identifies the new behavior.

## Validation and limits

Use controlled coordinator/runtime fixtures only: expired but retained sessions,
network/service/DNS changes during renewal, fresh already-matching DNS, readiness
later, cancellation/denial, duplicate callbacks, repeated denial, saved/unknown
results, shutdown and contention-budget preservation. Run strict formatting and
`scripts/check.sh`; build and signature-verify a local app without launching it.

The native macOS dialog itself and actual credential timeout remain real-system
integration tests needing explicit authorization. Rights are not made permanent;
macOS can ask again on a later required write. Readiness still depends on native
notification delivery; there is no polling fallback. No installation, publication,
real permission request or real DNS write is part of validation.
