# Manual DNS editing

> RETIRED 2026-10-28. Historical stage plan only. The manual editor was removed;
> exact SSID rules and their verified native transaction are the current product.
> See `docs/plans/2026-10-28-wifi-dns-rules.md`.

The owner requested stage two of the DNS integration on 2026-10-19: add DNS
editing to the existing inspection entry. This stage edits the current physical
network service on request.

Status: implemented and locally packaged. The full gate and read-only hardware
probe passed. Native authorization and actual system writes remain unexercised;
see `docs/evidence/2026-10-19-dns-editing/` for the validation record.

## Behavior

- Current DNS stays a fresh, read-only snapshot until Edit DNS is chosen.
- Open a compact, temporary native editor for automatic or custom IPv4/IPv6 DNS.
  Show the service and interface being changed. Keep invalid drafts and errors
  visible; opening or canceling the editor performs no write.
- Only Save requests system authorization. Validate literal addresses, then
  check the selected service, current network location, and previous DNS
  configuration again before committing. Preserve all other DNS settings.
- Apply the saved configuration and reread it. Report authorization, conflict,
  commit, apply, and verification failures without claiming success. Do not
  retry or restore blindly over another application's changes.
- Keep the editor and process alive during a save. No shell commands, setuid
  helper changes, persistent background worker, or automatic DNS enforcement.
- VPNs and other DNS managers can continue to override resolver selection.
  This editor does not coordinate third-party DNS tools.

## Validation

- Fixture tests for address validation, automatic mode, stale target/config,
  preservation of other keys, authorization denial, commit/apply failure, and
  readback mismatch. Use an injected backend; do not change the owner's DNS.
- Native UI tests for draft validation, save/cancel, error retention, busy-state
  protection, and menu action routing. Regenerate and inspect editor references
  in both languages and appearances.
- Run the profile's full gate, a read-only hardware smoke check, and package a
  local app. Report native authorization/save and updated-app performance
  checks separately if not performed. Do not install or publish.
