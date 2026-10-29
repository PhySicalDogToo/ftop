# Non-removable default DNS rule

Owner request on 2026-10-29: add one default block to the Wi-Fi DNS rules
surface. Every identifiable Wi-Fi that misses an exact-name rule uses this
default. Treat it as a separate rule that cannot be deleted, and explain how to
enter a preferred and alternate resolver.

## Decisions

- Exact, case-sensitive SSID rules have priority. The default rule is required
  and stores the same Automatic or normalized custom IPv4/IPv6 mode.
- The default card has no SSID or remove action. The global Automatic switching
  control remains the only way to pause every rule.
- Custom address order is preserved. The UI describes the first address as
  preferred and the second as alternate, while warning that macOS may select any
  available resolver and does not promise strict primary/backup failover.
- An unreadable/redacted name, disconnected Wi-Fi, Ethernet or a changed physical
  service remains a no-op because the app cannot safely establish the intended
  Wi-Fi association.
- Existing version-1 rule data migrates to an Automatic default. A fresh store is
  still globally disabled, so merely installing or opening the app cannot prompt
  for permission or write DNS.
- Keep the event-only lifecycle, per-association conflict/failure blocking,
  retained native authorization and complete transaction readback unchanged.

## Validation

- Test exact-over-default priority, Automatic and custom fallback, stable no-op,
  schema migration, address validation/order, draft retention and busy guards.
- Fit and render the rule surface in English/Chinese, light/dark, 520/380-point
  widths and every status phase. Inspect the generated references.
- Run `scripts/check.sh`, then build and verify a local app bundle. Do not install,
  launch, grant permissions or modify real DNS.
