#!/usr/bin/env bash
# PostUp helper for The Gate full-tunnel interface (called by wg-quick).
# Adds more-specific routes in table main for the WireGuard endpoint and for
# "networks that stay outside the tunnel" (LAN, RFC1918, CGNAT, …).
# wg-quick's suppress_prefixlength 0 policy already keeps connected routes
# working; these extra routes cover non-connected RFC1918/CGNAT and pin the
# endpoint even if fwmark handling is disturbed. Also blackholes IPv6 default
# egress so YunoHost cannot leak a home IPv6 address (v1 is IPv4-only).
#
# Usage: compy_route_up.sh <interface>
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
IFACE="${1:-compy}"
STATE="$DIR/compy_added_routes"
BYPASS_FILE="$DIR/compy_bypass_nets"
UNDERLAY_FILE="$DIR/compy_underlay.route"
ENDPOINT_FILE="$DIR/compy_endpoint"

# shellcheck disable=SC2329
log() { printf 'compy-route-up: %s\n' "$*" >&2; }

: >"$STATE"

underlay=""
if [[ -s "$UNDERLAY_FILE" ]]; then
    underlay="$(tr -d '\n' <"$UNDERLAY_FILE")"
fi
if [[ -z "$underlay" ]]; then
    # Fallback: wg-quick does not delete the default route in table main.
    underlay="$(ip -4 route show default table main 2>/dev/null | awk '
        /^default/ {
            via=""; dev="";
            for (i=1;i<=NF;i++) {
                if ($i=="via") via=$(i+1);
                if ($i=="dev") dev=$(i+1);
            }
            if (dev != "" && dev != "'"$IFACE"'") {
                if (via != "") printf "via %s dev %s", via, dev;
                else printf "dev %s", dev;
                exit
            }
        }')"
fi
if [[ -z "$underlay" ]]; then
    log "WARNING: could not determine the underlay default route; skip extra bypass routes (connected LAN routes still work via suppress_prefixlength 0)"
fi

route_exists() {
    [[ -n "$(ip -4 route show table main exact "$1" 2>/dev/null)" ]]
}

add_bypass() {
    local cidr="$1"
    [[ -n "$cidr" && -n "$underlay" ]] || return 0
    if route_exists "$cidr"; then
        log "skip $cidr (already in table main)"
        return 0
    fi
    # Do not install a route that would point at the tunnel itself.
    # shellcheck disable=SC2086
    if ip -4 route add "$cidr" $underlay table main 2>/dev/null; then
        printf '%s\n' "$cidr" >>"$STATE"
        log "added $cidr $underlay"
    else
        log "WARNING: could not add $cidr $underlay"
    fi
}

if [[ -n "$underlay" && -s "$ENDPOINT_FILE" ]]; then
    ep="$(tr -d '\n' <"$ENDPOINT_FILE")"
    if [[ "$ep" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        add_bypass "$ep/32"
    fi
fi

if [[ -s "$BYPASS_FILE" ]]; then
    # comma or whitespace separated CIDRs, optional comments after #
    tr ',;' ' ' <"$BYPASS_FILE" | tr -s ' \t' '\n' | while IFS= read -r cidr; do
        cidr="${cidr%%#*}"
        cidr="${cidr// /}"
        [[ -n "$cidr" ]] || continue
        add_bypass "$cidr"
    done
fi

# v1: do not tunnel IPv6, and do not let IPv6 default egress use the home WAN
# (diagnosis / Let's Encrypt / DynDNS would otherwise see a home AAAA).
# More-specific IPv6 LAN routes (ULA, link-local) are left untouched.
if ip -6 route replace blackhole default metric 8192 2>/dev/null; then
    printf '%s\n' "ipv6-blackhole-default" >>"$STATE"
    log "blackholed IPv6 default route (metric 8192)"
fi

chmod 600 "$STATE" 2>/dev/null || true
exit 0
