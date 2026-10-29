# Manual DNS editor validation

Scope: explicit manual DNS edits for the current identifiable physical Wi-Fi or
Ethernet service. No SSID rules, automatic switching, Clash changes or migration
from the separate tool.

## Safety and behavior

- Transaction fixtures inject a fake backend. They cover literal validation,
  preservation of all other DNS fields, adding a missing DNS protocol, automatic
  no-op, stale/retargeted baselines, location/link changes, authorization denial,
  busy lock, competing writer, commit outcomes, apply failure and verification
  mismatch. No fixture invokes the native writer.
- UI callbacks use fake save handlers. They cover explicit automatic/custom
  submission, cancel-before-save, invalid drafts, authorization cancellation,
  save-in-flight protection, partial/conflicting results and stale baselines.
- The CLI remains read-only. The real hardware probe invokes only DNSReader and
  DNSSettings.readTarget; its artifact excludes addresses, UUIDs and baseline
  tokens. Raw before/after snapshots stay in ignored build output.

## Checks

- Final `scripts/check.sh`: strict formatting and a warnings-as-errors build
  passed; both complete test runs passed with 124 tests. Optional image writers
  are gated in normal test runs; the editor renderer was run separately.
- Targeted UI tests: 16 passed; editor image generation: one test passed and
  produced twenty references.
- Opt-in hardware target read: one test passed. `dns-read-smoke.json` confirms
  a physical en0 target and a valid baseline; it contains counts and source only.
- Packaged CLI reads confirmed the manual DNS settings were unchanged before
  and after development. `hardware-smoke.json` records that comparison without
  addresses or UUIDs.
- `scripts/bundle.sh` produced the local `build/Ftop.app`. Strict deep codesign
  and Info.plist validation passed. No installed app was replaced or launched.

## Visual evidence

The twenty `dns-editor-*.png` files are native own-view renders with synthetic
addresses, not screen captures. They cover English/Chinese, light/dark,
automatic/custom, 460/360-point widths, saving and saved-but-not-applied errors.
The layout test checks visible controls, text labels and the scrollable address
area. The owner-facing image is the Chinese/light/custom/460 render.

Inspected by the primary agent: Chinese/light/custom/460,
English/dark/saved-error/360, Chinese/dark/busy/360 and English/light/automatic/460.
No clipped text or controls were observed in these references. The monitor
Scene and control-block layout are unchanged by stage two.

## Limits

- Native administrator authorization, real persistent commit/apply and effective
  resolver propagation were not exercised. Development did not change DNS.
- The connection fingerprint detects address, router and link changes. It cannot
  distinguish two SSIDs with identical network parameters without reading SSIDs.
- DNS is a network-service setting and persists across Wi-Fi networks. Other
  DNS managers and VPN resolvers may override its effect after saving. The legacy
  automatic switcher is rejected when detected; pausing it is insufficient.
- The running installed app was not replaced. Updated-app performance and a real
  panel drag sweep were not run. The monitor geometry and sampling path are
  unchanged, and the new editor is created only on demand.
