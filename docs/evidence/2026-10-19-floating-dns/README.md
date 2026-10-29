# Floating DNS figure validation

The new default-on DNS module is read-only. The regular row sits after the
machine readings and before processes. Its glyph uses the same Core Graphics
path grid, line width, neutral disc and sizing as the other badges. Three
endpoints converge into one outlined resolver. There is no usage arc or divider.

## Automated checks

- Final `scripts/check.sh`: strict formatting, warnings-as-errors build and two
  full passes of 214 tests. The targeted layout/DNS check passed 30 tests before
  the final thin-strip refinement; the final full gate includes that refinement
  and its added wide-thin regression test.
- The fit sweep checks requested widths 40–1500 and heights 20–1000 across seven
  machine shapes and ten module combinations. Every candidate is also checked
  at multiple scales, languages and stretch limits. DNS-specific cases cover
  exact candidate thresholds at minus/plus one point, IPv4, multiple addresses,
  full/scoped IPv6, unavailable/reference sources, and minimal module sets.
- Geometry checks assert no text/shape crosses scene bounds or process rows,
  every DNS-enabled form keeps its badge, and DNS contents never change scene
  dimensions. Hidden DNS restores the earlier module forms.
- Monitor fixtures cover notification coalescing, equal-state suppression,
  failure/recovery, stop/restart generations and unavailable notifications.
  Hover fixtures cover complete IPv6, eight addresses, narrow screens, every
  screen edge, negative screen origins and explicitly counted height overflow.
- The reference pass ran 19 rendering/DNS tests and produced 99 PNGs, including
  32 window references and six DNS-glyph references. Inspected the regular dark
  panel, narrow light strip, wide-thin dark strip, enlarged glyph, and regenerated
  README sizes image. `scripts/readme-media.sh` regenerated all maintained media.

## Native preview

Used a temporary copy of the packaged release executable with a separate bundle
identity to avoid replacing the installed application. Initial actual system DNS
was shown correctly. Dragged the real panel through regular, larger single
column, wide columns, tall/narrow, wide/thin and micro-badge forms. The native
figures remained within their layouts. The public `ftop size 300x420` command
restored a regular three-process form for performance measurement.

The preview was stopped after testing. No native location/network authorization,
DNS write, Clash reload, installation or publication was performed. No live DNS
setting was changed to trigger notifications; notification handling is tested
with fixtures, while initial real reads were verified separately.

## Hardware and package

`hardware-smoke.json` confirms the packaged CLI read succeeded and manual DNS
plus Clash configuration hashes were unchanged. Raw snapshots remain in ignored
build files. `validation.json` contains only validation counts/flags; native
screenshots containing actual process names were not retained here.

`scripts/bundle.sh` produced `build/Ftop.app`. Strict deep codesign validation,
plist lint and `git diff --check` passed. No installed app was replaced.

## Performance limit

`scripts/perf.sh <preview-pid>` sampled the release preview at a regular requested
300x420 size after the full test run. Memory was 41 MB. CPU was 1.1–1.8% of one
core across five samples, above the project's reference target of under 1%.
The earlier in-test measurement was 0.9–1.7% and 39 MB. There is no controlled
same-session baseline without DNS, so these samples do not establish how much
of the cost is caused by the new figure. Do not claim the CPU target passed.
The raw numeric samples are retained in `performance.json`.
