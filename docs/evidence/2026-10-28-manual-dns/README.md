# Manual system DNS scope — 2026-10-28

> Historical evidence only. The separate manual current-service editor described
> below was removed later on 2026-10-28. The native transaction safety remains in
> use by Wi-Fi DNS rules.

## Result

ftop now retains current DNS/source inspection and explicit one-shot editing of
macOS's current identifiable physical Wi-Fi/Ethernet service. The previous Wi-Fi
rule engine and all proxy cooperation are retired. Local build: **0.2.6 build 13**.
No installation, publication, real DNS write or native authorization prompt was
performed. Pre-existing unrelated work was preserved.

## Removed files and behavior

Removed ten production files and eight test files, including their embedded
controller mocks, configuration fixtures and permission/policy simulations:

- `Sources/FtopSensors/ClashConfiguration.swift`
- `Sources/FtopSensors/ClashDNSCooperation.swift`
- `Sources/FtopSensors/DNSAutomationRuntime.swift`
- `Sources/FtopSensors/DNSAutomationStore.swift`
- `Sources/FtopSensors/DNSWiFi.swift`
- `Sources/FtopCore/DNSAutomation.swift`
- `Sources/FtopCore/DNSAutomationPolicy.swift`
- `Sources/FtopApp/DNSAutomationCoordinator.swift`
- `Sources/FtopUI/DNSAutomationPanel.swift`
- `Sources/FtopUI/DNSAutomationContent.swift`
- `Tests/FtopSensorsTests/ClashConfigurationTests.swift`
- `Tests/FtopSensorsTests/ClashDNSCooperationTests.swift`
- `Tests/FtopSensorsTests/DNSAutomationRuntimeTests.swift`
- `Tests/FtopSensorsTests/DNSAutomationStoreTests.swift`
- `Tests/FtopSensorsTests/DNSWiFiTests.swift`
- `Tests/FtopCoreTests/DNSAutomationTests.swift`
- `Tests/FtopUITests/DNSAutomationTests.swift`
- `Tests/FtopUITests/DNSAutomationRenderTests.swift`

Also removed App lifecycle coordination, DNS menu automation callbacks, rules/review
theme dimensions, retained background authorization/mutation hooks and both
location-purpose plist keys. CoreWLAN/CoreLocation are no longer directly linked.
SSID/default rules, rule persistence and ownership, automatic timers/wake observers,
configuration scanning/hashing, controller HTTP/Unix calls, DNS YAML rewriting,
backups/restores and full core reloads are absent from the active product.

Existing user rule files, approvals and backups were not read, migrated or deleted.
Only the specifically retired project files were removed. A recovery copy of the
initial worktree text and SHA-256 manifest remains in the ignored validation
folder; it is not source input, part of the bundle or current executable code.

## Preserved safety and one boundary fix

- DNSReader, DNSStatusMonitor and DNSAddressList are byte-identical to the input
  worktree. The address parser keeps IPv4/IPv6 literal checks, order, equivalent
  IPv6/IPv4 duplicate removal, separators and invalid-input errors. No DNS query.
- DNSSettings and DNSChangeTransaction retain native SystemConfiguration sessions,
  authorization, non-waiting preferences lock, immutable location/service/interface/
  full-configuration baseline, rechecks under lock and immediately before commit,
  complete unrelated DNS fields, commit/apply distinction and a fresh preferences
  session for verification. Only ServerAddresses is changed.
- Kept the existing conflict guard against the known separate legacy DNS writer.
  It recognizes that DNS-writing tool only; it neither recognizes nor coordinates
  proxy clients. Its error is now generic. It does not create a helper or poll.
- Commit failure still rereads persistence where possible. Apply/verification
  failures distinguish unchanged, saved and unknown, expose current manual values
  when available, and never retry or roll back blindly over another writer.
- Saves remain off-main-thread and serialized by the editor's in-flight state.
  Closing/termination/update guards remain. Invalid inputs, cancellation and
  conflicts preserve the draft; uncertain/conflicted results require reopening.
- Fixed an existing boundary: Automatic previously treated an empty stored array
  as a no-op. It now deletes the ServerAddresses key even when that array is empty.
  Absence of the key remains a no-op without authorization or protocol creation.
- Success now reloads the verified target, keeps a concise result message visible,
  changes Cancel to Close, publishes the fresh system DNS state and requests a
  read-only refresh. It does not claim effective system resolvers equal the manual
  service addresses or that Automatic means DHCP only.

Read-only DNSStatusMonitor notifications, its 60-second fallback and a read refresh
on the shared hardware wake lifecycle remain intentionally: the owner required
that monitor and current-state display. They have no path to DNSSettings.save.
The removed 20-second automation timer and Wi-Fi/wake write coordinator are distinct
from these read-only refreshes and from the unchanged network-ranking grace period.

## Data flow

Read: SystemConfiguration -> DNSReader -> DNSState -> DNSStatusMonitor / explicit
menu read -> PanelModel / DNSDetails. Details show system-default or explicitly
labeled reference state, service addresses and source without inferring DHCP.

Save: explicit Edit -> fresh physical-service DNSEditTarget -> DNSAddressList ->
explicit Save -> DNSChangeTransaction baseline check -> authorization -> lock and
fresh conflict check -> modify only ServerAddresses -> connection recheck ->
commit -> apply -> fresh complete readback -> DNSWriteResult -> visible result and
system-state refresh. A failure ends the request with an explicit persistence
state. There is no scheduled or implicit write path and no proxy reload guarantee.

## Validation

- Changed Swift files formatted. Final `scripts/check.sh` passed strict formatting,
  warnings-as-errors build and two complete **209-test** runs. The earlier targeted
  manual-DNS run passed **48 tests**; the final gate also covers the subsequent
  Close-label change. Retiring tests accounts for the smaller suite; unrelated
  hardware/process/network/fit regressions remain in the gate.
- Mock-backend transactions cover automatic removal (including an empty key),
  custom IPv4/IPv6/multiple/duplicate addresses, invalid drafts/tokens, complete
  unrelated-field preservation, wrong service/interface/location, changes during
  authorization or immediately before/after commit, cancellation, lock/stage/
  commit/apply/readback failure, partial persistence and no blind overwrite.
- UI checks cover the single edit action, late-read rejection, the two modes,
  invalid input, saved-result retention, busy state, duplicate/cancel/close guards,
  preserved drafts, stale-baseline lockout and compact editor bounds.
- A real **read-only** smoke returned systemDefault, one default address, four
  services and a valid en0 physical-service baseline. `dns-read-smoke.json` retains
  only counts, interface and source; no real address/service identifiers.
- Regenerated **197 native reference PNGs**, including **32 editor references**
  across two languages/appearances, compact/default widths and automatic/custom/
  busy/error/saved/no-op states. All editor states were inspected in contact sheets;
  final English/custom and Chinese/automatic Close-label outputs were rechecked.
  Existing panel/reference forms and the full fit sweep remain covered. Existing
  README monitor media were left intact because the monitor Scene/control geometry
  did not change; the changed editor is documented by the new references.
- An isolated release preview showed current DNS/source, a menu with only Edit DNS,
  and an editor with Automatic (remove manual addresses) / Custom DNS. Mode was
  changed **as a draft** then canceled. Save was never clicked. Actual main-panel
  drags covered micro, tall/narrow, wide/thin and large forms; DNS fit and rankings
  below same-column basic information were observed. The only final cosmetic
  delta afterward was the post-save Close label, tested by the final native refs.
- Final bundle passed deep strict code-signature verification and plist lint.
  Both panel and CLI direct imports exclude CoreWLAN/CoreLocation. The panel binary
  has no retired controller/planner/location string markers. See validation.json.
- `scripts/perf.sh` measured the final visible 617 x 501 pt three-row CPU panel
  at 1 s, motion enabled, DNS display on, menu bar off, including its helper.
  Five three-second windows ranged **0.6–2.3% of one core**, mean **1.26%**, with
  **31.0–32.1 MiB summed top MEM**. This busy-background observation is not RSS,
  an energy result or a controlled performance-improvement claim. The existing
  under-1% CPU reference goal remains unmet. See performance.json.
- Only the verified owned preview/helper were stopped. No installed application,
  user config, system DNS or external client files were modified.

## Searches and remaining terms

`scope-audit.json` contains the full removed-file list, surviving tunnel lines,
writer call sites and baseline equality results. Active source/tests/support/package
have **zero** matches for Clash, Mihomo, clash-verge, direct-nameserver, redir-host,
external-controller, CoreWLAN, CoreLocation, DNSAutomation and DNSWiFi. DNS source/UI
have no HTTP/Unix/control-endpoint or file-based adapter path.

Remaining TUN/tunnel/utun occurrences are intentional and unchanged:

- ProcessNetworkProvider.swift and ProcessPresentation.swift explain that read-only
  socket activity can appear under both original application and proxy. The CLI's
  network diagnostic and ProcessNetworkUITests retain the same attribution scope.
- Providers.swift describes physical-interface counter selection.
- Core/UI/Sensors DNS fixtures use generic utun interfaces to verify resolver
  display and fallback. Reading the system resolver can legitimately show a VPN;
  these fixtures do not detect an application or configure a tunnel.
- Current product/architecture retain brief retirement notices and historical
  network-attribution context. The old automation plan, evidence and progress are
  explicitly labeled retired. Historical metrics/raw evidence are not rewritten
  as current product claims. The earlier performance assessment now marks its
  automation-specific suggestions obsolete.
- Ignored build caches and the recovery snapshot are not active source/tests and
  are excluded from the active-code search. The final executable was checked
  separately, so old cache objects cannot masquerade as shipped functionality.

## Real tests intentionally not performed

No real administrator authorization/cancellation, Automatic/custom save, commit/
apply failure, physical network change during a real write, or proxy/DNS-client
refresh experiment was run. Actual system-writing tests need separate explicit
owner authorization. Their deterministic transaction branches were tested with
mock backends only. No attempt was made to use networksetup, shell/AppleScript,
the setuid helper or any background enforcement loop for DNS.
