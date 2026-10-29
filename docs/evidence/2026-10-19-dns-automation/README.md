# Wi-Fi DNS automation evidence

> RETIRED 2026-10-28: all Wi-Fi DNS automation and Clash/Mihomo/TUN cooperation described below is historical build evidence, not current behavior or setup instructions.

## Scope

Exact SSID rules are evaluated outside the monitor sampler. The initial rules
are Office automatic and other identified Wi-Fi networks 114.114.114.114. Execution
is disabled initially and needs explicit authorization in each app session.
Saving rules pauses execution; pause and quit preserve the saved service DNS.

Core fixtures cover rule validation, corrupt persistence, unknown names,
connection changes, equivalent IP representations, and an external DNS change
that remains blocked across DHCP renewal. Sensors fixtures cover retained
authorization, queued cancellation, fresh association/configuration checks,
Clash contract validation, isolated child environments, backup planning,
idempotent JavaScript wrapping, stale reviews and partial-apply failure handling.
Existing scripts are syntax checked without executing their main function.
Regression fixtures also reject an external complete-DNS change between a
successful transaction and ownership recording, bind approval to the reviewed
candidate digest, and prevent the final reload when its late cancellation guard
fails. Uncertain association reads do not count as confirmed disconnects.

UI fixtures cover rule edits, callbacks, drafts, busy state, queued Enable/Pause,
and the separate Clash review action. The main monitor Scene and sampling path
are unchanged.

## Validation results

`scripts/check.sh` passed strict formatting, a warnings-as-errors build and two
full passes of 196 tests. The 27 targeted runtime/cooperation/Wi-Fi tests passed
after the final ownership, reviewed-digest and cancellation changes. Render-only
tests are opt-in and were run separately to produce the references below.

`scripts/bundle.sh` produced the local `build/Ftop.app`. Strict deep codesign
verification and plist lint passed. The installed running copy was not replaced.

## Native references

The 24 PNG files render the app's own AppKit content offscreen with synthetic
SSID and public DNS values. They cover English/Chinese, light/dark appearances,
500/640-point widths, and disabled, active, applying, blocked and authorization
states. No desktop capture or real Wi-Fi name is included.

Inspected Chinese/light disabled at 640, English/dark active at 500,
Chinese/dark blocked at 500, and English/light authorization at 500. Controls and
messages remain readable, and long rule lists scroll while actions stay visible.

## Read-only hardware checks

`clash-prepare-smoke.json` is an explicitly enabled real preparation check. It
reports success, whether a migration is needed, and the reviewed file count.
The actual installed Mihomo kernel accepted the candidate in a private temporary
directory. Child processes use a minimal environment and local validation inputs;
the candidate is not loaded into the running core. No review Apply action ran.

`hardware-smoke.json` records only counts and equality checks for packaged DNS
reads and Clash configuration hashes. Raw snapshots stay in ignored build files;
resolver addresses, service identifiers, secrets and subscription contents are
not published in this evidence folder.
The packaged CLI read succeeded; manual DNS and all seven existing Clash files
were identical to the development baseline.

## Practical limits

No real location/admin authorization, service DNS save, Clash reload, or round
trip between Office and another Wi-Fi was performed. The owner must exercise those
native prompts and network transitions in the packaged app. Performance and the
real monitor-panel drag sweep were not repeated; the running installed copy was
left untouched.

Clash cooperation supports the default Clash Verge Rev/Mihomo layout. It is a
persistent, separately reviewed migration with private backups. A changed runtime
configuration invalidates the in-memory reload approval. Unknown layouts and
competing saved-DNS writers stop automation instead of causing a reassertion loop.

Clash does not share ftop's advisory file lock. Before/after comparisons catch
stale reviews and many concurrent changes, but cannot make another application's
writes atomic with ftop's. The review explicitly asks the owner not to edit,
update or reapply Clash configurations during Apply. Failure retains recovery
backups and avoids blind rollback or a second reload.
