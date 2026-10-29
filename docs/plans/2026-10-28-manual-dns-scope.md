# One-shot manual DNS scope (superseded)

> Superseded later on 2026-10-28 by the owner's exact Wi-Fi-name rule request.
> The proxy-cooperation retirement and transaction-safety decisions remain current;
> the one-shot-only product boundary and manual editor do not. See
> `docs/plans/2026-10-28-wifi-dns-rules.md`.

Owner request on 2026-10-28: retain current DNS/source inspection and explicit
system DNS editing; retire every Wi-Fi-name rule and proxy-cooperation path.

## Scope

- Preserve the existing DNSReader, DNSStatusMonitor, DNSSettings,
  DNSChangeTransaction, DNSAddressList, details and manual editor.
- Remove the ten automation/cooperation production files and eight associated
  test files, their UI/theme callbacks and location usage descriptions.
- DNSNativeBackend directly implements DNSWriteBackend. Remove only automation
  authorization and mutation hooks. Retain existing transaction/identity/conflict
  safety and separate DNS-writer detection; do not detect proxy clients.
- Automatic deletes the manual ServerAddresses key, including an empty array;
  custom validates literal IPv4/IPv6 with stable duplicate removal. Preserve all
  unrelated fields and report a fresh readback, not an assumed effective resolver.
- Verified success stays visible and refreshes the panel; uncertain persistence
  or a changed baseline blocks another save until the editor is reopened.
- Preserve all pre-existing unrelated work. An ignored baseline snapshot and
  SHA-256 manifest allow a final comparison without git reset/checkout.

## Validation and delivery

- All writes use injected fake backends. Check invalid/duplicate input, empty-key
  removal, full-field preservation, cancellation, service/location/link changes,
  lock/stage/commit/apply failures and readback/partial persistence.
- Format changed Swift files; run the complete scripts/check.sh gate.
- Regenerate editor/control/panel references and inspect changed states at both
  widths, languages and appearances. Check actual small/narrow/wide/large panel
  forms using an isolated bundle with updates off; never save real DNS.
- Audit source/tests/current documentation and final binary imports for retired
  symbols, client endpoints and location dependencies. Classify remaining tunnel
  terms as generic read-only DNS/network monitoring or historical evidence.
- No install, publication, system DNS write or native authorization test.

Status: locally complete and validated. Final gate: two 209-test runs; mock
transaction/UI cases, native references, read-only hardware/editor checks and
actual panel drags passed. Build 13 remains local and uninstalled. Evidence:
`docs/evidence/2026-10-28-manual-dns/`.
