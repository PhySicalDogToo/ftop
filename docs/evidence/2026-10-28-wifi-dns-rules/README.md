# Event-driven Wi-Fi DNS rules validation

> Historical evidence for the exact-rule stage. On 2026-10-29, unmatched
> identifiable Wi-Fi changed from a no-op to a required, non-removable default
> rule. See `docs/evidence/2026-10-29-default-dns-rule/`.

Date: 2026-10-28. The original rule implementation was build 0.2.6 (14); the
entry/editor simplification is local build 0.2.6 (15). Neither was installed or
published.

## Result

- ftop now stores exact, case-sensitive Wi-Fi-name rules. Each rule selects
  Automatic (remove the current physical service's manual ServerAddresses) or a
  normalized custom list of literal IPv4/IPv6 addresses.
- Save & Apply validates and persists the whole draft, asks for Wi-Fi-name access
  only when required, establishes native authorization for the current app
  session, and evaluates the current connection. Later evaluations are triggered
  by SSID, BSSID, link, Wi-Fi power and wake events; there is no polling loop.
- Unmatched, redacted, disconnected and non-Wi-Fi states are no-ops. A changed
  service/SSID/interface/configuration, external DNS edit, failed write or unknown
  verification result stops automatic retry for that association.
- The implementation has no Clash/Mihomo adapter, file access, controller call,
  reload, backup or TUN configuration. Proxy/VPN resolver behavior remains outside
  this feature.
- A follow-up removes the separate current-service editor. More now contains one
  Wi-Fi DNS rules row: hover shows a read-only system DNS snapshot, while click
  opens the rules panel directly. One-off manual changes remain in macOS settings.

## Data flow and ownership

1. FtopCore owns versioned rule values, address/rule validation and the pure
   per-association policy.
2. FtopSensors reads the connected association through CoreWLAN after explicit
   CoreLocation permission, stores v2 rules, and reuses the existing native
   DNSChangeTransaction. Retired v1 automation is not read or migrated.
3. FtopApp coalesces event bursts, selects one exact rule, and coordinates session
   authorization plus verified writes. There is no second writer UI to pause around.
4. FtopUI receives values and callbacks only. Its AppKit utility panel uses the
   existing palette, status colors, rounded tracks and Theme-owned metrics.

Only ServerAddresses is replaced or deleted. The location, service, interface,
complete original DNS dictionary and connection fingerprint remain transaction
baselines. Authorization, a non-waiting preferences lock, a final pre-commit
association check, commit, apply and complete readback are all retained.

## Automated validation

Follow-up entry/editor simplification (build 15):

- `scripts/check.sh` passed strict recursive formatting, warning-as-error build,
  and two complete 226-test runs.
- Nine focused DNS entry/rules UI tests passed. They cover the direct rules action,
  zero settings writes from the row, full IPv4/IPv6/source tooltip text, control-
  character sanitization, tooltip registration/removal, draft retention, busy
  guards, transaction-error presentation and window bounds.
- The manual editor source and its two UI/reference test files were removed. Active
  Sources/Tests have no `DNSEditor`, manual-edit suspension or public
  `DNSSettings.readTarget/save` entry point; the rule transaction tests remain.

- `scripts/check.sh` passed after the final compact-width fix: strict recursive
  formatting, warning-as-error build, then two complete 241-test runs.
- Focused DNS runs passed 78 tests during integration. The final rule-only run
  passed 28 tests, and the final reference run passed both render tests.
- Tests cover exact/case/space SSIDs; IPv4, IPv6, multiple and duplicate addresses;
  invalid input; automatic empty-key deletion; unmatched no-op; stable-match
  suppression; new-association reset; external-change/failure blocking; permission
  and authorization cancellation; expired retained rights; SSID/interface/service
  conflicts; stop-before-commit; complete post-write verification; store damage;
  draft retention; busy-window guards; and accessibility/fitting.
- Every DNS write test uses a fake backend. No automated test changed the real
  network configuration.

## Native UI validation

- The follow-up regenerated the settings references in English/Chinese and
  light/dark appearances. The Wi-Fi DNS rules title and Open value fit without
  truncation, overlap or clipping. The official README media workflow was rerun
  with the bundled Pillow runtime and the resulting settings image was inspected.
- The main floating Scene geometry did not change; its existing fit sweep and
  full reference render tests passed. No real application DNS write, permission
  prompt or administrator authorization was invoked for this follow-up.

- Generated 36 AppKit references under `references/`: English/Chinese, light/dark,
  all eight phases, 520-point wide and 380-point compact forms.
- The final images are exactly 1040 or 760 Retina pixels wide. Heights are 814 to
  1118 pixels (407 to 559 points), below the 720-point test cap.
- Visual inspection covered off, waiting, permission, authorization, applying,
  active, unmatched and blocked states. Long English headings, Chinese messages,
  rule cards, popup labels, error text and bottom actions remain inside the window.
  Compact mode hides only the redundant Automatic switching text; the switch keeps
  its accessibility label.
- An isolated, uniquely identified app copy with a temporary HOME opened the real
  DNS detail menu and rules window. Adding blank rules and invoking Save produced
  local validation only and kept the error visible. Save & Apply with valid data,
  Wi-Fi Access and every native permission prompt were deliberately not used.
- The same isolated panel was dragged through thin, small, wide and large forms.
  The DNS row and all existing hardware/process layouts stayed fitted.

## Performance and binary audit

- With the final isolated release panel visible at the normal 300 x 420 form and
  one-second sampling, five samples measured panel CPU 0.7-1.9%, helper CPU
  0.2-0.4%, and about 27 MiB + 2.1 MiB memory. Combined CPU averaged 1.6% of one
  core under concurrent desktop load. There is no same-session pre-change control,
  so this is not evidence of a regression or of meeting the reference CPU budget.
- Empty/default rules do not start Wi-Fi event monitoring. Active rules add native
  event listeners only; no rule code runs on the hardware sample or render tick.
- The final ad-hoc bundle passed deep strict code-signature verification and plist
  lint. It links the expected AppKit, CoreLocation, CoreWLAN, Security and
  SystemConfiguration frameworks. The shared FtopSensors target also makes the CLI
  binary link the wireless/location frameworks, but the CLI does not instantiate
  the coordinator or request permission; `ftop dns` remains read-only.
- Active Sources/Tests/Support contain no Clash, Mihomo, clash-verge,
  direct-nameserver or controller endpoint references. Remaining `TUN` text is the
  pre-existing read-only process-network attribution disclaimer only.

## Intentionally not exercised

- No real location permission was granted.
- No native network administrator authorization was accepted.
- No real DNS value was written, deleted, committed or applied.
- No live Wi-Fi transition, wake-time write, authorization-expiry recovery or
  proxy/VPN adoption was claimed.
- No app was installed, published or deployed.
