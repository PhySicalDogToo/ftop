#!/bin/bash
# Prints the running panel and its collector children's CPU/memory over 15 seconds.
# Budget: under 1% of one core and under 60 MB (docs/architecture). Quit any other copy first:
# the panel is single-instance, so a stale one is what gets measured.
# An explicit PID measures only that panel, for an isolated local preview.
set -euo pipefail
pid="${1:-$(pgrep -x FtopPanel || true)}"
[ -n "$pid" ] || { echo "ftop is not running; start it with: ftop" >&2; exit 1; }
[[ "$pid" =~ ^[0-9]+$ ]] || { echo "Select one panel with: scripts/perf.sh <pid>" >&2; exit 1; }
selected=(-pid "$pid")
for child in $(pgrep -P "$pid" || true); do
    command="$(ps -p "$child" -o comm= || true)"
    case "$command" in
        */ftop-helper|*/nettop) selected+=(-pid "$child") ;;
    esac
done
echo "panel and direct collectors: pid command cpu% memory (five intervals, 3 s apart)"
# The first top sample is lifetime usage; omit it. Native network collection is
# part of the panel process, not an invisible extra child. Include a command
# collector too if a future implementation introduces one.
top -l 6 -s 3 "${selected[@]}" -stats pid,command,cpu,mem | awk '
    /^Processes:/ { sample++; if (sample > 1) print "sample " sample - 1 }
    sample > 1 && $1 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+[.][0-9]+$/ { print }
'
