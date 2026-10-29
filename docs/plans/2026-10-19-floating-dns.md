# Current DNS in the floating panel

> Historical implementation plan. The monitor display and hover remain current,
> but the separate Current DNS menu was replaced on 2026-10-28 by a read-only
> tooltip on the direct Wi-Fi DNS rules entry.

Owner request: show current system DNS addresses between the machine readings and
the process list, using a glyph with the same native drawing and style as the
other badges. Verify the result through all window sizes and transitions.

Status: implemented and packaged. The full gate passed twice with 214 tests;
reference images, README media and real window dragging were checked. Native
reads preserved network configuration. CPU sampling exceeded the reference
target; results and limits are in `docs/evidence/2026-10-19-floating-dns/`.

## Display and data

- DNS is an optional added module, enabled for existing and new configurations.
  A plain badge uses the existing disc, 16-unit Core Graphics glyph, line width
  and neutral tint. Three address endpoints converge into one resolver node.
- Column layouts keep DNS at the end of the statistics group, before processes;
  it never becomes a column of its own. Compact, corner and rich/vertical strips
  show a bounded address. Plain strips and the smallest layout keep the badge
  and full hover, preserving room for the existing essential readings.
- The row's natural width is fixed. Addresses may fill the available width;
  otherwise the first address is shortened and additional addresses are counted.
  Full addresses and the source appear in the existing hover chip. Service
  reference data is explicitly labeled rather than claimed as system default.
- The hover chip wraps complete IPv6 addresses and stays within the pointer's
  screen. If a list cannot fit vertically, it reports omitted complete lines.
  The current More-row tooltip is the secondary read-only detail surface.
- Sensors observes SystemConfiguration changes on a utility queue. Initial read,
  coalesced notifications, wake and a 60-second fallback refresh are independent
  of hardware sampling. No DNS lookup, authorization or network write is added.
  Disabling the module stops the observer and discards in-flight completions.

## Validation

- Existing fit sweep plus DNS enabled/disabled and minimal module combinations.
- All layout candidates with IPv4, multiple addresses, long/scoped IPv6,
  reference data and unavailable state; same dimensions for every reading.
- Candidate transition thresholds at minus/plus one point; no text/shape or DNS
  hover region overlapping processes or leaving the scene.
- New icon and bounded multiline-hover fixtures. Regenerate and inspect panel
  references and README media, then drag a real preview panel through small,
  narrow, thin and large sizes. Measure the running preview with perf.sh.
- Run the project gate, package and verify the local app. Leave network settings
  and the installed running application unchanged.
