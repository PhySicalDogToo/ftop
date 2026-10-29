# Wi-Fi DNS rules and Clash TUN cooperation

> RETIRED 2026-10-28. Historical plan only. Its Clash/Mihomo/TUN cooperation,
> fixed defaults, fallback polling and proxy reload flow remain retired. Exact
> SSID rules were later reintroduced with a smaller event-driven design; use
> `docs/plans/2026-10-28-wifi-dns-rules.md`. None of the Clash approval or reload
> steps below apply.

Owner request: add exact Wi-Fi-name DNS rules to ftop, allow custom rules, keep
Clash TUN and avoid competing DNS writers. Defaults are Office automatic and other
identified Wi-Fi networks 114.114.114.114.

Status: implemented and packaged locally. The final project gate passed twice
with 196 tests. Native prompts, real DNS writes, live Wi-Fi transitions and real
Clash reloads were not exercised. Results are recorded in
`docs/evidence/2026-10-19-dns-automation/` and `docs/progress/2026-10-19.md`.

## Ownership and lifecycle

- Ftop owns the physical Wi-Fi service's ServerAddresses only. Preserve all
  other DNS fields. Clash uses redir-host and the system DNS upstream while TUN,
  proxy nodes and routing stay intact.
- Rules are saved independently of execution. First launch is disabled; every
  app session needs explicit Enable/Resume to obtain native network authority.
  Saving rules pauses; it does not apply them. Opening manual DNS editing also
  pauses automatic switching. Pause/quit do not clear or restore DNS.
- Request location permission only from an explicit action, to read the SSID.
  Do not scan networks, obtain coordinates or infer a fixed default from an
  unavailable name. Ethernet, unknown/redacted SSID and disconnected states
  perform no write.
- Use Wi-Fi/wake events and a 20-second fallback, outside the monitor sampler.
  A new identifiable connection synchronizes once, including when manual DNS
  already matches. Stable state only reads. Detect external saved-DNS changes
  and stop instead of reasserting; a renewed IP cannot clear that conflict.
- Native authorization is interactive only at Enable/Resume. Subsequent writes
  use the retained session without interaction. Expiration needs explicit user
  authorization. Pause immediately disarms queued work; check SSID, service,
  full configuration baseline and cancellation again under lock before commit.
  After applying, compare the fresh complete DNS configuration to the verified
  transaction result before recording ownership. A competing change in that
  interval must stop automation rather than becoming its new baseline.

## Clash integration

- Support the known default Clash Verge Rev profile layout and local Mihomo
  controller. Require compatible DNS settings and explicitly approve the exact
  runtime configuration before full reloads. Changed profiles need review again.
- Prepare a read-only plan. Show persistent script wrapping, DNS-only runtime
  changes, backup location, full reload and stale restore-snapshot archiving.
  Apply only from the plan's separate action. Never execute existing script main.
- Preserve existing scripts/legacy portal exceptions. Validate candidate YAML
  with Mihomo in an isolated directory. Refuse unknown layouts, DNS override,
  unsafe paths, symlinks and stale file baselines. Back up exact originals with
  private permissions and compare each file before replacement.
- Never call the old app or reuse the setuid monitor helper. Detect the old
  automatic switcher and refuse simultaneous ownership. Do not run periodic
  restore/reset writes. Preserve backups and report partial changes on failure.

## Validation and delivery

- Pure Core policy/config tests; fake authorization/cancellation/runtime tests;
  isolated persistence and Clash planner fixtures; native UI callback tests and
  own-view references in both languages/appearances and narrow widths.
- Run the project gate, inspect references, package the local app, verify its
  signature and compare read-only hardware baselines. Do not change the owner's
  live DNS or Clash configuration during development.
- Report native location/admin prompts, live Wi-Fi round trips, real Clash
  reloads, performance and panel interaction checks separately when not run.
  Do not install or publish without approval.
