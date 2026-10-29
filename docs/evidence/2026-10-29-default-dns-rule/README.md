# Default Wi-Fi DNS rule validation

Date: 2026-10-29. Local build: 0.2.6 (16). The app was not installed,
launched, notarized or published.

## Result

- Every identifiable Wi-Fi now selects exactly one DNS target: an exact,
  case-sensitive SSID rule first, otherwise the required default rule.
- The default rule is a separate AppKit card with no SSID or delete action. It
  supports Automatic or a normalized custom IPv4/IPv6 list and is governed by
  the existing global Automatic switching control.
- Custom address order is preserved. The default card explains that the first
  address is preferred and the second alternate, while warning that macOS does
  not guarantee strict primary/backup failover.
- Redacted/unreadable Wi-Fi names, disconnection, Ethernet and an identity change
  still cause no write because the association cannot be verified safely.

## Compatibility and safety

- Persisted rule schema version 2 adds the required default mode. Version-1 rule
  data decodes with an Automatic default; exact rules and their identifiers remain
  unchanged. The retired automation key is still ignored.
- A fresh store defaults to Automatic but leaves the global switch off, preventing
  a first-launch permission prompt or DNS write. Existing enabled configurations
  adopt the requested Automatic fallback.
- The existing native authorization, non-waiting lock, connection/configuration
  conflict checks, commit/apply/readback verification, external-writer detection
  and per-association failure blocking are unchanged.

## Validation

- Twenty-three focused Core, store, UI and render tests passed. Coverage includes
  exact-over-default priority, Automatic/custom fallback, stable no-op, invalid and
  duplicate addresses, version-1 migration, draft retention, non-removability,
  preferred/alternate help, busy guards and compact/wide fitting.
- `scripts/check.sh` passed strict formatting, warning-as-error production build,
  and two complete 228-test runs.
- Generated 32 native rule-window references: English/Chinese, light/dark,
  520/380-point widths and every current status phase. The default card, status
  label, scrolling exact-rule region and bottom actions were visually inspected.
  All fixed controls remained visible; only the exact-rule list scrolls when needed.
  The images are retained in this directory's `references/` folder.
- `scripts/bundle.sh` produced an ad-hoc signed arm64 `build/Ftop.app`. Deep strict
  signature verification passed; the bundle is version 0.2.6 (16), about 5.1 MiB.

No real Wi-Fi switch, location permission, network authorization, DNS mutation,
installation or app launch was performed.
