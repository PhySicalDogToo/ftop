# Read-only DNS inspection

> Historical first-stage plan. The read-only path remains, while its editing,
> SSID-rule and permission exclusions were superseded by later stages.

Scope requested by the owner on 2026-10-19: integrate current DNS and source
display only. DNS management, SSID rules, permission changes, and Clash
configuration remain out of scope.

## Implementation

- Put a Sendable DNS snapshot and service metadata in FtopCore.
- Read SystemConfiguration in FtopSensors on demand. Prefer Global/DNS and label
  a per-service fallback as a reference. Do not infer DHCP from missing manual
  settings; preserve IPv6 scope and unavailable states.
- Add a More action to the existing control block. FtopApp reads on a utility
  task, outside the UI and sensor queues, and ignores canceled requests.
- Present a native read-only menu with full addresses, source and relevant
  service details. Keep the monitor scene and status-item behavior unchanged.
- Provide `ftop dns [--json]` for the same read-only snapshot without starting a
  panel. Record the feature in both README languages.

## Validation

- Fixture tests for default/reference/unavailable priority, wired and dynamic
  services, IPv6-only and scoped addresses, manual versus service DNS.
- UI tests for source labels, full address text, read-only actions, row fit and
  late-response suppression. Regenerate and inspect settings references.
- Run `scripts/check.sh`, a real SystemConfiguration read through the CLI, and
  package the local app. Compare DNS before and after the read.
- Measure the updated panel if a safely isolated instance is available. Report
  any native interaction or performance checks that are not run.
