# DNS authorization refresh validation — 2026-11-01

## Scope and findings

The old coordinator could await administrator authorization and then pass its
pre-authorization SSID, rule and service baseline to the writer. The existing
transaction normally rejected a changed target, but the coordinator treated
pre-write service unavailability as stopped/error. Passive reads could display
a new SSID beside the old match/error.

Authorization now resumes at a new read/match boundary. A tentative policy copy
is discarded with the entire old snapshot. Only a fresh unchanged match or fresh
write request can follow. Location authorization uses the existing coalesced
monitor callback. There is no second location delegate or recursive evaluation.

Native dynamic-store service/IP/link/DNS/setup hints allow an association that
preceded service readiness to recover without another permission-button click.
`noPhysicalService` is waiting only before transaction entry. Failed or unknown
transactions and external edits retain the existing association block. Native
DNSSettings authorization, complete dictionary preservation, nonblocking lock,
commit/apply and full readback were not rewritten or weakened.

## Automated checks

- `swift format --in-place --recursive Package.swift Sources Tests`: completed.
- `scripts/check.sh`: passed strict formatting, build and two 242-test runs.
  The first full attempt exposed a test-only wall-clock deadline problem when
  existing synchronous layout suites monopolized MainActor. Waiting now counts
  actual scheduling opportunities and throws on exhaustion; the final gate passed.
- Final `swift format lint --strict --recursive Package.swift Sources Tests` and
  `swift build -Xswiftc -warnings-as-errors`: passed after the status-card wrapping
  follow-up.
- Focused coordinator/runtime/render run: 24 tests passed. Thirteen coordinator
  regressions use a controlled authorization continuation, injected monitor/store,
  locked Wi-Fi/DNS fixture and recorded fake writes; no native backend is created.
- Scenarios include hotspot-to-exact-rule switching during authorization; service
  or DNS changes on the same SSID; fresh already-matching settings without writes;
  location authorization callbacks; service readiness after a later event without
  another authorization; no service before authorization; denial/cancellation and
  duplicate callbacks; task/shutdown cancellation; explicit Save & Apply; external
  changes and uncertain transactions retaining their write blocks.
- Runtime tests retain fake transaction-backend verification and now also check
  task cancellation at the authorization/mutation latch.
- `git diff --check`: passed.
- `scripts/bundle.sh` and `codesign --verify --deep --strict build/Ftop.app`:
  passed. The local ad-hoc-signed app remains 0.2.6 (16); no release/version bump
  was made. The earlier generated bundle is preserved at
  `build/Ftop-before-dns-auth-refresh-20261101.app`. Neither bundle was launched.

## Visual checks

Commands used only offscreen native windows and sample values:

```sh
FTOP_DNS_RULES_RENDER_DIR=docs/evidence/2026-11-01-dns-authorization-refresh/references/rules \
FTOP_RENDER_DIR=docs/evidence/2026-11-01-dns-authorization-refresh/references/panel \
swift test --filter 'DNSWiFiRulesRenderTests|RenderTests.writeReferenceImages'
```

After the text-wrapping correction, the rules render suite was rerun with the
same rules output directory. There are 36 rules references (English/Chinese,
light/dark, 380/520-point forms and every phase) and 32 monitor references across
16 requested sizes in both appearances. Wide/compact fit and waiting-text height
assertions pass. Inspected waiting references in both languages/widths/appearances,
and representative 96x32, 90x330, 760x30, 300x420 and 1700x1000 monitor references.

Inspection exposed status text being measured at the outer stack width rather
than the card's inset width. Correcting preferredMaxLayoutWidth retains the last
wrapped line. No monitor Scene, hardware sampling, process ranking or adaptive
monitor geometry changed. No live production app was launched or dragged; monitor
size checks here are offscreen references, not an interactive hardware trial.

## Remaining limits / real tests not performed

- Readiness recovery is event driven and has no time cutoff. It covers information
  becoming ready later when macOS delivers a service/IP/link/configuration hint,
  even if the SSID and effective resolver addresses did not change.
- Registration failure or missing system notifications still leave a gap: there
  is no polling fallback. The app can remain waiting until a later Wi-Fi/wake hint
  or an explicit recheck. Delayed SSID visibility with no subsequent hint has the
  same limit. These notification-loss cases are not claimed fixed.
- Real location permission, administrator authorization/cancellation/expiration,
  hotspot/company Wi-Fi switching and physical DNS writes were not exercised.
  Those require a separate authorized hardware test.
- No installation, running production bundle, release, Git push, or real DNS
  mutation was performed. Reference export did not capture the user's screen.
