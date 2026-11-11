#!/usr/bin/env bash
# PostDown helper for the Compy full-tunnel interface (called by wg-quick).
# Removes only the routes this package added in PostUp.
#
# Usage: compy_route_down.sh <interface>
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
STATE="$DIR/compy_added_routes"

# shellcheck disable=SC2329
log() { printf 'compy-route-down: %s\n' "$*" >&2; }

if [[ ! -s "$STATE" ]]; then
    exit 0
fi

while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    if [[ "$item" == "ipv6-blackhole-default" ]]; then
        ip -6 route del blackhole default metric 8192 2>/dev/null || true
        log "removed IPv6 blackhole default"
        continue
    fi
    ip -4 route del "$item" table main 2>/dev/null || true
    log "removed $item"
done <"$STATE"

rm -f "$STATE"
exit 0
