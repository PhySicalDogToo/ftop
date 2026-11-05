# Event-driven Wi-Fi DNS rules

Owner request on 2026-10-28: allow an exact DNS target per Wi-Fi name, apply it
when the rule is first saved and when Wi-Fi changes, and keep the UI consistent
with the floating monitor. Do not restore any Clash/Mihomo/TUN cooperation.

## Scope and decisions

- Preserve current DNS/source display. More exposes one direct Wi-Fi-rules entry;
  its hover shows the latest read-only system DNS snapshot. Remove the separate
  current-service editor and leave one-off manual changes to macOS Network settings.
- Store a validated v2 list of exact, case-sensitive SSID rules. Each rule selects
  Automatic (delete manual ServerAddresses) or a normalized custom IPv4/IPv6 list.
- A non-removable default rule uses the same mode and handles every identifiable
  Wi-Fi not matched by an exact rule. Redacted/disconnected Wi-Fi and Ethernet are
  still no-ops. See `docs/plans/2026-10-29-default-dns-rule.md`.
- Save & Apply stores the draft, obtains explicit Wi-Fi-name access and native
  session authorization when required, then evaluates the current connection.
- React to native Wi-Fi association/link/power/name/configuration events and wake.
  The 2026-11-04 owner request adds bounded event-driven DNS reassertion; do not
  poll, use a shell/helper, or put work on the monitor sample path.
- After administrator authorization, discard all tentative inputs and reread Wi-Fi,
  physical service, connection identity and DNS before matching again. Location
  authorization reuses the existing monitor callback and coalesced evaluation.
- Pre-transaction `noPhysicalService` waits for readiness without blocking that
  association. Native SystemConfiguration service/IP/link/configuration hints share
  the Wi-Fi event queue, including when effective DNS addresses remain unchanged.
- Publish SSID, selected rule, DNS and phase together. Opening enabled rules uses
  a full evaluation instead of retaining an old rule/error after a passive read.
- Authorization cancellation/failure suppresses new prompts until explicit Save &
  Apply. A confirmed no-write authorization denial on a retained session now
  requests one renewal prompt automatically (2026-11-06), then rereads and rematches
  the network. Saved/unknown results never retry. Successful unchanged matches
  never need a DNS write or credential renewal. No observer or
  readiness loop bypasses failed-write or repeated-contention protection.
- Reuse DNSChangeTransaction and its native backend for service identity, immutable baselines,
  lock/commit/apply/readback, complete field preservation, and conflict handling.
- Detect a changed SSID/interface/service/configuration immediately before mutation.
  Reassert the first five observed off-rule DNS address changes within a rolling
  60 seconds; the sixth yields that association to the external value until a new
  connection or explicit save. Uncertain/failed writes still block immediately.
  Metadata-only changes, duplicate hints and verified own writes do not count.
- Keep FtopUI value-only and AppKit-native. Use Theme-owned main-panel palette,
  metrics and rounded tracks; preserve drafts and fit both compact and wide forms.
- Never inspect, configure, reload, back up or call any proxy client or controller.

## Validation and delivery

- Cover address and rule validation, exact-over-default matching, automatic
  empty-key deletion, stable match suppression, per-association conflict blocking,
  permission/auth cancellation, identity changes and full post-write verification
  with pure or injected fake backends only.
- Format changed Swift files and run `scripts/check.sh`.
- Generate and inspect the rule window in both languages, light/dark appearances,
  wide/compact widths and every status phase. Do not save or apply in a real app.
- Audit active code and binaries for proxy-client integration and confirm only the
  rules path uses CoreWLAN/CoreLocation. Run an isolated bundle and performance
  measurement without installing it or modifying real DNS.

Status: locally complete and validated, with a later UI simplification that removed
the current-service editor and made the More row open rules directly. The original
gate passed two 241-test runs; the follow-up gate passed two 226-test runs and its
settings references were inspected. Full validation is recorded in the evidence.
The build remains local and uninstalled. No real permission, authorization, Wi-Fi
switch or DNS write was exercised. Evidence:
`docs/evidence/2026-10-28-wifi-dns-rules/` and
`docs/evidence/2026-10-29-default-dns-rule/`.
