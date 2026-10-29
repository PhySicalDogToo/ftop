# Read-only DNS inspection evidence

## Verified

- `scripts/check.sh`: formatting, build with warnings as errors, and both full
  test runs passed (89 tests).
- 13 DNS Core/Sensors fixture tests and 5 UI tests cover global versus reference
  selection, missing state, wired/dynamic services, IPv6 scopes, IPv6-only
  presentation, full address strings, read-only actions, and late responses.
- `hardware-smoke.json` records a real read with unchanged Wi-Fi DNS settings and
  rejection of an unsupported write flag. It omits the owner's resolver addresses
  and service identifiers. The packaged release CLI was also exercised.
- Settings references were regenerated; `settings-en.png`,
  `settings-zh-dark.png`, and the composed README settings image were inspected.
- `scripts/bundle.sh`, strict deep codesign verification, and plist validation
  passed for the local `build/Ftop.app`.

## Limits

- No actual native-menu interaction was exercised on the new running app. The
  DNS command routed through the same reader was exercised on real hardware;
  the UI action and menu contents were exercised in AppKit tests.
- No updated-app performance measurement was taken. The already installed copy
  remained running and was not replaced.
- The floating monitor layout did not change; no real drag sweep was repeated.
  The changed control block's layout was rendered and checked separately.
- No DNS writes, hostname lookups, permission requests, or proxy access occurred.
