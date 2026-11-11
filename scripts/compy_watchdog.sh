#!/usr/bin/env bash
# If the Compy full tunnel is up but has no recent handshake, take it down so
# this box can reach the internet through the home WAN again. LAN routes are
# never taken over by the tunnel (see compy_route_up.sh); this only restores
# the IPv4 default route. The unit is left disabled-at-boot as it was; the
# admin can start the tunnel again from the panel once the VPS is healthy.
#
# Intended to run from compy-watchdog.timer (every minute).
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
IFACE="compy"
FLAG="$DIR/compy_watchdog_tripped"
LOG="$DIR/compy_watchdog.log"
# PersistentKeepalive is 25s; 180s is several missed keepalives, not a blip.
MAX_AGE="${COMPY_WATCHDOG_MAX_AGE:-180}"
SERVICE="wireguard_client@${IFACE}.service"

log() {
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '%s %s\n' "$ts" "$*" >>"$LOG" 2>/dev/null || true
    printf 'compy-watchdog: %s\n' "$*" >&2
}

# Nothing to do if the interface is not up.
if ! ip link show dev "$IFACE" >/dev/null 2>&1; then
    exit 0
fi
if ! command -v wg >/dev/null 2>&1; then
    exit 0
fi

handshake="$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2; exit}')"
now="$(date +%s)"
reason=""
if [[ -z "$handshake" ]]; then
    reason="could not read latest-handshakes"
elif [[ ! "$handshake" =~ ^[0-9]+$ ]]; then
    reason="unexpected handshake value"
elif ((handshake == 0)); then
    # 0 means no handshake since the interface came up. Give a new interface
    # a grace period (same MAX_AGE) based on oper-state / if age if we can.
    reason="no handshake since the interface came up"
    # If the interface was just started, skip this run.
    if [[ -d "/sys/class/net/$IFACE" ]]; then
        # Approximate uptime from SYS_UPTIME - iface stats is not portable;
        # use the service ActiveEnterTimestamp if systemd is present.
        started="$(systemctl show -p ActiveEnterTimestampMonotonic --value "$SERVICE" 2>/dev/null || true)"
        uptime_us="$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo 0)"
        # ActiveEnterTimestampMonotonic is usec; /proc/uptime is seconds.
        if [[ "$started" =~ ^[0-9]+$ ]]; then
            age=$(( now - started / 1000000 ))
            # started is monotonic usec since boot, not epoch. Recompute.
            boot_mono_sec="${uptime_us%.*}"
            age=$(( boot_mono_sec - started / 1000000 ))
            if ((age >= 0 && age < MAX_AGE)); then
                exit 0
            fi
        fi
    fi
elif ((now - handshake > MAX_AGE)); then
    reason="last handshake was $((now - handshake))s ago (limit ${MAX_AGE}s)"
else
    # Healthy. Clear a stale flag only if the tunnel recovered on its own
    # after a previous trip (it would have been down, so this is rare).
    rm -f "$FLAG"
    exit 0
fi

log "Taking the Compy tunnel down: $reason. Internet will use the home WAN until you start the tunnel again from the Public access panel. LAN access is unchanged."
printf '%s\n' "$reason" >"$FLAG"
chmod 600 "$FLAG" 2>/dev/null || true

# Stop only the Compy unit. Do not disable it here so a reboot can retry;
# if the VPS is still down the watchdog will trip again after MAX_AGE.
systemctl stop "$SERVICE" >>"$LOG" 2>&1 || {
    # Fallback if the systemd unit is not the one holding the iface.
    wg-quick down "$DIR/${IFACE}.conf" >>"$LOG" 2>&1 || true
}

log "Tunnel stopped."
exit 0
