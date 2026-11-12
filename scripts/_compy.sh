#!/bin/bash
# The Gate helpers for this fork of wireguard_client_ynh.
# Sourced from scripts/config, scripts/install, and scripts/upgrade.
#
# Product name: The Gate (the VPS gateway to your Compy).
# The app id, interface name (`compy`), setting keys, and install paths
# are kept so a live install upgrades in place.
#
# Paths (all under the app install dir, already backed up by scripts/backup):
#   $install_dir/ssh/id_ed25519          client SSH key (root 600)
#   $install_dir/ssh/id_ed25519.pub
#   $install_dir/ssh/known_hosts         pinned VPS host keys
#   $install_dir/ssh/keyscan.pending     last ssh-keyscan result
#   $install_dir/keys/wg_client          WG private key (root 600)
#   $install_dir/keys/wg_client.pub
#   $install_dir/compy.conf              wg-quick client conf (root 600)
#   $install_dir/vps_setup.sh            copy of the VPS script (from conf/)
#   $install_dir/ports_from_yunohost.sh  copy of the firewall extractor

# The interface name is fixed. Do not add it to the `interfaces` tags list
# (that would also generate an upload widget for it).
COMPY_IF="compy"
COMPY_DIAGNOSIS_SERVER="${COMPY_DIAGNOSIS_SERVER:-diagnosis.yunohost.org}"

# Provided by scripts/config (or install) before these functions run.
install_dir="${install_dir:-}"
app="${app:-wireguard_client}"

_compy_paths() {
    COMPY_SSH_DIR="$install_dir/ssh"
    COMPY_SSH_KEY="$COMPY_SSH_DIR/id_ed25519"
    COMPY_SSH_PUB="$COMPY_SSH_DIR/id_ed25519.pub"
    COMPY_KNOWN_HOSTS="$COMPY_SSH_DIR/known_hosts"
    COMPY_KEYSCAN_PENDING="$COMPY_SSH_DIR/keyscan.pending"
    COMPY_WG_DIR="$install_dir/keys"
    COMPY_WG_KEY="$COMPY_WG_DIR/wg_client"
    COMPY_WG_PUB="$COMPY_WG_DIR/wg_client.pub"
    COMPY_CONF="$install_dir/${COMPY_IF}.conf"
    # Prefer the copy shipped in the installed package; fall back to install_dir.
    if [[ -n "${YNH_APP_BASEDIR:-}" && -f "$YNH_APP_BASEDIR/conf/vps_setup.sh" ]]; then
        COMPY_VPS_SCRIPT="$YNH_APP_BASEDIR/conf/vps_setup.sh"
    else
        COMPY_VPS_SCRIPT="$install_dir/vps_setup.sh"
    fi
}

_compy_setting() {
    ynh_app_setting_get --key="$1"
}

_compy_set() {
    ynh_app_setting_set --key="$1" --value="$2"
}

_compy_is_wg_key() {
    [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

# ---------------------------- key generation ----------------------------

compy_ensure_ssh_key() {
    _compy_paths
    mkdir -p "$COMPY_SSH_DIR"
    chmod 700 "$COMPY_SSH_DIR"
    chown root:root "$COMPY_SSH_DIR"
    if [[ ! -f "$COMPY_SSH_KEY" ]]; then
        ssh-keygen -t ed25519 -N "" -f "$COMPY_SSH_KEY" -C "compy@${app:-wireguard_client}" >/dev/null
        ynh_print_info "Created a new ed25519 SSH key at $COMPY_SSH_KEY"
    fi
    chmod 600 "$COMPY_SSH_KEY"
    chmod 644 "$COMPY_SSH_PUB"
    chown root:root "$COMPY_SSH_KEY" "$COMPY_SSH_PUB"
    [[ -f "$COMPY_KNOWN_HOSTS" ]] || touch "$COMPY_KNOWN_HOSTS"
    chmod 600 "$COMPY_KNOWN_HOSTS"
}

compy_ensure_wg_keys() {
    _compy_paths
    mkdir -p "$COMPY_WG_DIR"
    chmod 700 "$COMPY_WG_DIR"
    if [[ ! -f "$COMPY_WG_KEY" ]]; then
        wg genkey >"$COMPY_WG_KEY"
        ynh_print_info "Created a new WireGuard client key at $COMPY_WG_KEY"
    fi
    wg pubkey <"$COMPY_WG_KEY" >"$COMPY_WG_PUB"
    chmod 600 "$COMPY_WG_KEY"
    chmod 644 "$COMPY_WG_PUB"
    chown root:root "$COMPY_WG_KEY" "$COMPY_WG_PUB"
}

# ---------------------------- port list ----------------------------

compy_default_ports() {
    # Source the extractor if needed. Packaged path first.
    if ! declare -F compy_ports_from_yunohost >/dev/null; then
        local helper=""
        if [[ -n "${YNH_APP_BASEDIR:-}" && -f "$YNH_APP_BASEDIR/scripts/ports_from_yunohost.sh" ]]; then
            helper="$YNH_APP_BASEDIR/scripts/ports_from_yunohost.sh"
        elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/ports_from_yunohost.sh" ]]; then
            helper="$(dirname "${BASH_SOURCE[0]}")/ports_from_yunohost.sh"
        elif [[ -n "${install_dir:-}" && -f "$install_dir/ports_from_yunohost.sh" ]]; then
            helper="$install_dir/ports_from_yunohost.sh"
        fi
        if [[ -n "$helper" ]]; then
            # shellcheck disable=SC1090
            source "$helper"
        else
            echo "tcp:25,80,443,587,993;udp:"
            return 0
        fi
    fi
    compy_ports_from_yunohost
}

# ---------------------------- SSH helpers ----------------------------

_compy_require_host() {
    local host user sport
    host="$(_compy_setting compy_vps_host)"
    user="$(_compy_setting compy_ssh_user)"
    sport="$(_compy_setting compy_ssh_port)"
    [[ -n "$host" ]] || ynh_die --message="Enter the VPS IP address or hostname first, then Save, then run this action."
    [[ -n "$user" ]] || ynh_die --message="Enter the SSH user first (often debian on OVH)."
    if [[ ! "$sport" =~ ^[0-9]+$ ]] || ((sport < 1 || sport > 65535)); then
        ynh_die --message="SSH port must be a number between 1 and 65535."
    fi
    COMPY_HOST="$host"
    COMPY_USER="$user"
    COMPY_SPORT="$sport"
}

compy_ssh_base_opts() {
    # Common options. Host-key checking is added by the caller.
    _compy_paths
    COMPY_SSH_OPTS=(
        -i "$COMPY_SSH_KEY"
        -p "$COMPY_SPORT"
        -o "IdentitiesOnly=yes"
        -o "BatchMode=yes"
        -o "PreferredAuthentications=publickey"
        -o "ConnectTimeout=15"
        -o "ServerAliveInterval=5"
        -o "ServerAliveCountMax=12"
        -o "ExitOnForwardFailure=yes"
        -o "RequestTTY=no"
        -o "KbdInteractiveAuthentication=no"
        -o "UserKnownHostsFile=$COMPY_KNOWN_HOSTS"
    )
}

# ssh-keyscan the host, save pending keys, print SHA256 fingerprints.
compy_keyscan() {
    _compy_paths
    _compy_require_host
    mkdir -p "$COMPY_SSH_DIR"
    local tmp
    tmp="$(mktemp)"
    # -H hashes hostnames; we want the raw line so we can pin exactly.
    # IPv4 first: -4. Timeout 10s. Types: ed25519, rsa, ecdsa.
    # -T 10 is ssh-keyscan's own timeout; the outer timeout is a hard cap
    # so a stuck keyscan cannot leave a YunoHost action log open.
    if ! timeout --signal=TERM --kill-after=5 20 \
            ssh-keyscan -4 -T 10 -p "$COMPY_SPORT" -t "ed25519,rsa,ecdsa" "$COMPY_HOST" \
            >"$tmp" 2>/dev/null </dev/null; then
        rm -f "$tmp"
        ynh_die --message="Could not reach ${COMPY_HOST} port ${COMPY_SPORT} with ssh-keyscan. Check the IP, the SSH port, and the OVH (or other) firewall. If a log entry stays open, see Tools > Logs or run: sudo systemctl restart yunohost-api"
    fi
    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        ynh_die --message="ssh-keyscan returned no host keys for ${COMPY_HOST}. The VPS may still be booting, or port ${COMPY_SPORT} is not SSH."
    fi
    mv "$tmp" "$COMPY_KEYSCAN_PENDING"
    chmod 600 "$COMPY_KEYSCAN_PENDING"
}

compy_fingerprint_text() {
    _compy_paths
    if [[ ! -s "$COMPY_KEYSCAN_PENDING" ]]; then
        printf '%s\n' "No fingerprint cached. Click Test connection."
        return 0
    fi
    # ssh-keygen -lf prints "256 SHA256:... host (ED25519)"
    ssh-keygen -lf "$COMPY_KEYSCAN_PENDING" 2>/dev/null || cat "$COMPY_KEYSCAN_PENDING"
}

compy_host_is_pinned() {
    # Quiet: return 1 if not pinned or if host is not configured yet.
    # Do not ynh_die — this is also called from getters.
    _compy_paths
    local host sport
    host="$(ynh_app_setting_get --key=compy_vps_host 2>/dev/null || true)"
    sport="$(ynh_app_setting_get --key=compy_ssh_port 2>/dev/null || true)"
    sport="${sport:-22}"
    [[ -n "$host" && -s "$COMPY_KNOWN_HOSTS" ]] || return 1
    ssh-keygen -F "[${host}]:${sport}" -f "$COMPY_KNOWN_HOSTS" >/dev/null 2>&1 \
        || ssh-keygen -F "$host" -f "$COMPY_KNOWN_HOSTS" >/dev/null 2>&1
}

compy_pin_pending_host() {
    _compy_paths
    _compy_require_host
    [[ -s "$COMPY_KEYSCAN_PENDING" ]] \
        || ynh_die --message="Click Test connection first, compare the fingerprint, then pin the host key."
    mkdir -p "$COMPY_SSH_DIR"
    touch "$COMPY_KNOWN_HOSTS"
    # Drop any previous key for this host (rotation / typo) then append.
    ssh-keygen -R "[${COMPY_HOST}]:${COMPY_SPORT}" -f "$COMPY_KNOWN_HOSTS" >/dev/null 2>&1 || true
    ssh-keygen -R "$COMPY_HOST" -f "$COMPY_KNOWN_HOSTS" >/dev/null 2>&1 || true
    cat "$COMPY_KEYSCAN_PENDING" >>"$COMPY_KNOWN_HOSTS"
    chmod 600 "$COMPY_KNOWN_HOSTS"
    rm -f "${COMPY_KNOWN_HOSTS}.old" 2>/dev/null || true
    _compy_set compy_host_pinned "1"
    ynh_print_info "Pinned the SSH host key for ${COMPY_HOST}:${COMPY_SPORT}. Future connections will refuse a different key (good: that would be a warning sign)."
}

# Run a remote command as the configured user, with sudo -n when not root.
# Host key must already be pinned (StrictHostKeyChecking=yes).
# The command is always run under `bash -c` so callers can pass shell
# constructs (pipes, if/then). stdin is not forwarded (ssh -n and
# </dev/null): a YunoHost action's stdin can stay open and would
# otherwise hang the SSH session and leave an operation log stuck.
# A hard `timeout` is a last resort if the VPS stops responding.
# Set COMPY_SSH_TIMEOUT (seconds) to override the default (90).
# Returns 124 on timeout. Callers should treat that as a failure and
# use ynh_die with a plain message; details are in Tools > Logs.
compy_ssh() {
    _compy_paths
    _compy_require_host
    compy_ensure_ssh_key
    compy_ssh_base_opts
    compy_host_is_pinned || ynh_die --message="The VPS SSH host key is not pinned yet. Click Test connection, check the fingerprint against the provider console, then click Pin host key. If a log entry stays open, see Tools > Logs or run: sudo systemctl restart yunohost-api"
    local remote_cmd="$1"
    local timeout_s="${COMPY_SSH_TIMEOUT:-90}"
    local remote
    # printf %q so quotes and semicolons in the command stay one argv.
    if [[ "$COMPY_USER" == "root" ]]; then
        remote="bash -c $(printf '%q' "$remote_cmd")"
    else
        # -n: never prompt for a password. Fail clearly if sudo is not passwordless.
        remote="sudo -n -- bash -c $(printf '%q' "$remote_cmd")"
    fi
    local rc=0
    timeout --signal=TERM --kill-after=10 "$timeout_s" \
        ssh -n "${COMPY_SSH_OPTS[@]}" \
        -o "StrictHostKeyChecking=yes" \
        "${COMPY_USER}@${COMPY_HOST}" \
        "$remote" \
        </dev/null || rc=$?
    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        ynh_print_err "SSH to ${COMPY_USER}@${COMPY_HOST} timed out after ${timeout_s}s. See Tools > Logs for details. If a log entry stays open, run: sudo systemctl restart yunohost-api"
        return 124
    fi
    return "$rc"
}

compy_ssh_script() {
    # Usage: compy_ssh_script ARG...
    # Feeds the VPS setup script on stdin: `bash -s -- args`.
    _compy_paths
    _compy_require_host
    compy_ensure_ssh_key
    compy_ssh_base_opts
    compy_host_is_pinned || ynh_die --message="The VPS SSH host key is not pinned yet. Click Test connection, check the fingerprint, then click Pin host key. If a log entry stays open, see Tools > Logs or run: sudo systemctl restart yunohost-api"
    [[ -f "$COMPY_VPS_SCRIPT" ]] || ynh_die --message="The VPS setup script was not found at $COMPY_VPS_SCRIPT. Reinstall or upgrade the app so conf/vps_setup.sh is shipped. See Tools > Logs for details."
    # ssh(1) joins the remote command into a string that the remote shell
    # evaluates. A port list contains ";" and would otherwise be split.
    local quoted="" arg
    for arg in "$@"; do
        quoted+=" $(printf '%q' "$arg")"
    done
    local remote
    if [[ "$COMPY_USER" == "root" ]]; then
        remote="bash -s --${quoted}"
    else
        remote="sudo -n -- bash -s --${quoted}"
    fi
    # apt on a fresh VPS can take several minutes. 600s is the hard cap
    # so a stalled install cannot leave a YunoHost action log open.
    # stdin is the setup script (do not use ssh -n here).
    local timeout_s="${COMPY_SSH_SCRIPT_TIMEOUT:-600}"
    local rc=0
    timeout --signal=TERM --kill-after=15 "$timeout_s" \
        ssh "${COMPY_SSH_OPTS[@]}" \
        -o "StrictHostKeyChecking=yes" \
        "${COMPY_USER}@${COMPY_HOST}" \
        "$remote" \
        <"$COMPY_VPS_SCRIPT" || rc=$?
    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        ynh_print_err "The VPS setup script timed out after ${timeout_s}s. See Tools > Logs for details. If a log entry stays open, run: sudo systemctl restart yunohost-api"
        return 124
    fi
    return "$rc"
}

# ---------------------------- WG client conf ----------------------------

COMPY_MTU="${COMPY_MTU:-1420}"
COMPY_IP_CHECK_URL="${COMPY_IP_CHECK_URL:-https://ip.yunohost.org}"
COMPY_VERIFY_HANDSHAKE_TRIES="${COMPY_VERIFY_HANDSHAKE_TRIES:-15}"

_compy_second_host() {
    # Given a CIDR (10.99.0.0/24) print the second host (10.99.0.2) and the
    # first host (10.99.0.1) as: first second prefix. Uses python3.
    python3 -c '
import sys, ipaddress
net = ipaddress.ip_network(sys.argv[1], strict=False)
hosts = list(net.hosts())
if len(hosts) < 2:
    sys.exit("subnet too small")
print(hosts[0], hosts[1], net.prefixlen, net.with_prefixlen)
' "$1"
}

# Auto list: connected IPv4 subnets plus RFC1918, link-local, and CGNAT
# (100.64.0.0/10, used as the WAN on Starlink). These stay in the main
# routing table so LAN / underlay access is never swallowed by 0.0.0.0/0.
compy_default_bypass_nets() {
    python3 -c '
import subprocess, ipaddress, sys

defaults = [
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("100.64.0.0/10"),
]
seen = list(defaults)
try:
    out = subprocess.check_output(["ip", "-4", "-o", "route", "show", "table", "main"], text=True)
except Exception:
    out = ""
for line in out.splitlines():
    parts = line.split()
    if not parts or parts[0] in ("default", "unicast"):
        continue
    # "default" already skipped; a line starts with the prefix or "nexthop"
    prefix = parts[0]
    dev = ""
    if "dev" in parts:
        dev = parts[parts.index("dev") + 1]
    if dev in ("lo", "compy", "wg0"):
        continue
    try:
        net = ipaddress.ip_network(prefix, strict=False)
    except Exception:
        continue
    if net.version != 4 or net.prefixlen == 0 or net.is_multicast or net.is_unspecified:
        continue
    if any(net == x for x in seen):
        continue
    seen.append(net)
print(", ".join(str(n) for n in seen))
'
}

compy_current_bypass_nets() {
    local saved
    saved="$(_compy_setting compy_bypass_nets || true)"
    if [[ -z "$saved" ]]; then
        saved="$(compy_default_bypass_nets)"
    fi
    printf '%s' "$saved"
}

compy_resolve_ipv4() {
    # Resolve a host or pass through an IPv4 address. Empty on failure.
    # getaddrinfo has no native timeout; wrap the process so DNS cannot hang
    # a getter or an action (and leave a YunoHost log open).
    timeout --signal=TERM --kill-after=2 10 python3 -c '
import socket, sys
host = (sys.argv[1] or "").strip()
if not host:
    sys.exit(0)
try:
    print(socket.getaddrinfo(host, None, socket.AF_INET)[0][4][0])
except Exception:
    sys.exit(0)
' "$1" || true
}

compy_save_underlay_and_endpoint() {
    # Must be called BEFORE wg-quick up, while the home WAN default is active.
    _compy_paths
    local line via dev underlay
    line="$(ip -4 route show default table main 2>/dev/null | awk '
        /^default/ {
            via=""; dev=""; metric=0+0;
            for (i=1;i<=NF;i++) {
                if ($i=="via") via=$(i+1);
                if ($i=="dev") dev=$(i+1);
                if ($i=="metric") metric=$(i+1);
            }
            if (dev != "" && dev != "compy" && dev != "wg0") {
                printf "%s\t%s\t%s\n", metric, via, dev;
            }
        }' | sort -n | head -1)"
    via="$(printf '%s' "$line" | cut -f2)"
    dev="$(printf '%s' "$line" | cut -f3)"
    underlay=""
    if [[ -n "$dev" && -n "$via" ]]; then
        underlay="via ${via} dev ${dev}"
    elif [[ -n "$dev" ]]; then
        underlay="dev ${dev}"
    fi
    if [[ -n "$underlay" ]]; then
        printf '%s\n' "$underlay" >"$install_dir/compy_underlay.route"
        chmod 600 "$install_dir/compy_underlay.route"
    else
        rm -f "$install_dir/compy_underlay.route"
        ynh_print_err "Could not detect the current IPv4 default route; LAN connected routes will still be kept by wg-quick, but extra bypass routes may be skipped."
    fi

    local host ep
    host="$(_compy_setting compy_vps_host || true)"
    ep="$(compy_resolve_ipv4 "$host")"
    if [[ -n "$ep" ]]; then
        printf '%s\n' "$ep" >"$install_dir/compy_endpoint"
        chmod 600 "$install_dir/compy_endpoint"
    else
        rm -f "$install_dir/compy_endpoint"
    fi

    printf '%s\n' "$(compy_current_bypass_nets)" >"$install_dir/compy_bypass_nets"
    chmod 600 "$install_dir/compy_bypass_nets"
}

compy_write_client_conf() {
    # Args: server_pubkey endpoint_host endpoint_port server_ip peer_ip prefixlen subnet
    # Full-tunnel IPv4: AllowedIPs=0.0.0.0/0 and Table=auto (wg-quick default).
    # wg-quick then installs an fwmark and `ip rule ... suppress_prefixlength 0`,
    # so more-specific routes in table main (connected LAN, Starlink CGNAT
    # underlay, static routes) keep working, and WireGuard's own packets
    # (fwmarked) still use the home WAN to reach the endpoint.
    # A computed AllowedIPs list that "subtracts" RFC1918/CGNAT is more
    # brittle: it can miss a connected subnet or the Starlink underlay and
    # cut off LAN/SSH. We still install extra main-table routes for the
    # panel bypass list and the endpoint /32 (PostUp) as belt and braces.
    # IPv6 is not tunnelled; PostUp blackholes the IPv6 default route.
    # Do not set DNS= (YunoHost's local resolver must keep running).
    _compy_paths
    compy_ensure_wg_keys
    local server_pub="$1" endpoint_host="$2" endpoint_port="$3"
    local server_ip="$4" peer_ip="$5" prefixlen="$6" subnet="$7"
    local priv
    priv="$(tr -d '\n' <"$COMPY_WG_KEY")"
    _compy_is_wg_key "$server_pub" || ynh_die --message="The VPS returned an invalid server public key."
    if [[ -f "$COMPY_CONF" ]]; then
        cp -a "$COMPY_CONF" "${COMPY_CONF}.bak"
    fi
    umask 077
    cat >"$COMPY_CONF" <<EOF
[Interface]
# Generated by The Gate (full-tunnel IPv4). Do not set DNS= or Table=off.
# AllowedIPs 0.0.0.0/0 + wg-quick Table=auto keeps connected LAN/underlay
# routes via suppress_prefixlength 0. PostUp adds the bypass-list routes
# and blackholes IPv6 default egress. Tunnel subnet is ${subnet}.
Address = ${peer_ip}/${prefixlen}
PrivateKey = ${priv}
MTU = ${COMPY_MTU}
PostUp = ${install_dir}/compy_route_up.sh %i
PostDown = ${install_dir}/compy_route_down.sh %i

[Peer]
PublicKey = ${server_pub}
Endpoint = ${endpoint_host}:${endpoint_port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    chown root:root "$COMPY_CONF"
    chmod 600 "$COMPY_CONF"
}

compy_install_watchdog_units() {
    local pkg dest_svc dest_tmr
    pkg="$(compy_pkg_dir)"
    dest_svc="/etc/systemd/system/compy-watchdog.service"
    dest_tmr="/etc/systemd/system/compy-watchdog.timer"
    [[ -n "${install_dir:-}" ]] || return 0
    if [[ -f "$pkg/conf/compy-watchdog.service" ]]; then
        sed "s|__INSTALL_DIR__|${install_dir}|g" "$pkg/conf/compy-watchdog.service" >"$dest_svc"
        chmod 644 "$dest_svc"
    fi
    if [[ -f "$pkg/conf/compy-watchdog.timer" ]]; then
        cp "$pkg/conf/compy-watchdog.timer" "$dest_tmr"
        chmod 644 "$dest_tmr"
    fi
    systemctl daemon-reload || true
}

compy_enable_watchdog() {
    compy_install_watchdog_units
    systemctl enable --now compy-watchdog.timer >/dev/null 2>&1 || true
}

compy_disable_watchdog() {
    systemctl disable --now compy-watchdog.timer >/dev/null 2>&1 || true
}

compy_stop_tunnel() {
    _compy_paths
    systemctl stop "wireguard_client@${COMPY_IF}.service" 2>/dev/null || true
    if ip link show dev "$COMPY_IF" >/dev/null 2>&1; then
        wg-quick down "$COMPY_CONF" 2>/dev/null || true
    fi
}

compy_bring_up_tunnel() {
    _compy_paths
    [[ -f "$COMPY_CONF" ]] || ynh_die --message="Missing $COMPY_CONF"
    [[ -x "$install_dir/compy_route_up.sh" ]] || ynh_die --message="Missing $install_dir/compy_route_up.sh. Upgrade or reinstall the app so the route helpers are shipped."
    compy_save_underlay_and_endpoint
    # Always stop first: systemctl start on a RemainAfterExit oneshot is a
    # no-op if the unit is already active, and a half-up interface must not
    # be left in place.
    compy_stop_tunnel
    # Do not enable at boot until verify-then-commit succeeds.
    if ! systemctl start "wireguard_client@${COMPY_IF}.service"; then
        ynh_print_err "Failed to start wireguard_client@${COMPY_IF}. The default route was not committed. Check journalctl -u wireguard_client@${COMPY_IF}."
        return 1
    fi
    return 0
}

compy_commit_tunnel() {
    _compy_paths
    ynh_app_setting_set --key="${COMPY_IF}_atboot" --value=1
    ynh_app_setting_set --key="compy_full_tunnel" --value=1
    systemctl enable --quiet "wireguard_client@${COMPY_IF}.service" || true
    yunohost service add "wireguard_client@${COMPY_IF}" \
        --description="The Gate tunnel (WireGuard client ${COMPY_IF}, full tunnel)" \
        --test_status="wg | grep \"interface: ${COMPY_IF}\" -q" 2>/dev/null || true
    rm -f "$install_dir/compy_watchdog_tripped" "${COMPY_CONF}.bak"
    compy_enable_watchdog
}

compy_rollback_tunnel() {
    # Take the new tunnel down, restore the previous conf if any, and try to
    # bring the previous (usually split-tunnel) conf back so the box is no
    # worse than before. Never enable-at-boot here.
    local reason="${1:-verification failed}"
    _compy_paths
    ynh_print_err "Rolling back the full-tunnel config: $reason"
    compy_stop_tunnel
    systemctl disable --quiet "wireguard_client@${COMPY_IF}.service" 2>/dev/null || true
    ynh_app_setting_set --key="${COMPY_IF}_atboot" --value=0
    ynh_app_setting_set --key="compy_full_tunnel" --value=0
    if [[ -f "${COMPY_CONF}.bak" ]]; then
        mv -f "${COMPY_CONF}.bak" "$COMPY_CONF"
        ynh_print_info "Restored the previous WireGuard client config."
        systemctl start "wireguard_client@${COMPY_IF}.service" 2>/dev/null || true
    else
        rm -f "$COMPY_CONF"
    fi
}

compy_verify_full_tunnel() {
    # Handshake + ping the VPS tunnel IP + confirm ip.yunohost.org sees the
    # VPS public IPv4. Any failure should be followed by a rollback.
    local server_ip="$1"
    local expect_ip="${2:-}"
    local handshake _try seen
    for ((_try=1; _try<=COMPY_VERIFY_HANDSHAKE_TRIES; _try++)); do
        handshake="$(wg show "$COMPY_IF" latest-handshakes 2>/dev/null | awk '{print $2; exit}')"
        if [[ "$handshake" =~ ^[0-9]+$ ]] && ((handshake > 0)); then
            ynh_print_info "WireGuard handshake is up (latest-handshakes=$handshake)."
            break
        fi
        sleep 2
        handshake=""
    done
    if [[ ! "$handshake" =~ ^[0-9]+$ ]] || ((handshake == 0)); then
        printf '%s' "No WireGuard handshake with the VPS after $((COMPY_VERIFY_HANDSHAKE_TRIES * 2)) seconds. Check the provider firewall (allow UDP $(_compy_setting compy_wg_port)) and journalctl -u wireguard_client@${COMPY_IF}."
        return 1
    fi
    if ! ping -c 3 -W 3 "$server_ip" >/dev/null 2>&1; then
        printf '%s' "Handshake is up but ping to ${server_ip} (VPS tunnel address) failed."
        return 1
    fi
    ynh_print_info "Ping to ${server_ip} (VPS tunnel address) succeeded."

    if [[ -z "$expect_ip" ]]; then
        expect_ip="$(_compy_setting compy_public_ip || true)"
    fi
    if [[ -z "$expect_ip" ]]; then
        expect_ip="$(compy_resolve_ipv4 "$(_compy_setting compy_vps_host || true)")"
    fi

    local seen_ip=""
    if command -v curl >/dev/null 2>&1; then
        seen_ip="$(curl -4 -fsS --max-time 15 "$COMPY_IP_CHECK_URL" 2>/dev/null | tr -d '[:space:]' || true)"
    else
        seen_ip="$(python3 -c '
import sys, urllib.request
url = sys.argv[1]
try:
    print(urllib.request.urlopen(url, timeout=15).read().decode().strip())
except Exception:
    sys.exit(0)
' "$COMPY_IP_CHECK_URL" || true)"
    fi
    if [[ ! "$seen_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s' "Could not read a public IPv4 from ${COMPY_IP_CHECK_URL} through the tunnel (got '${seen_ip:-empty}'). Outbound MASQUERADE on the VPS may have failed."
        return 1
    fi
    ynh_print_info "${COMPY_IP_CHECK_URL} returned ${seen_ip}."
    if [[ -n "$expect_ip" && "$seen_ip" != "$expect_ip" ]]; then
        printf '%s' "Public IPv4 through the tunnel is ${seen_ip}, but the VPS is ${expect_ip}. The default route is not going through the VPS as expected."
        return 1
    fi
    if [[ -z "$expect_ip" ]]; then
        ynh_print_err "Could not determine the VPS public IP to compare against; accepting ${seen_ip} from ${COMPY_IP_CHECK_URL}."
    fi
    _compy_set compy_public_ip "$seen_ip"
    return 0
}

compy_start_and_verify() {
    local server_ip="$1"
    local expect_ip="${2:-}"
    local reason=""
    if ! compy_bring_up_tunnel; then
        reason="Failed to start wireguard_client@${COMPY_IF}. The default route was not committed. Check journalctl -u wireguard_client@${COMPY_IF}."
        _compy_set compy_last_result "fail: $reason"
        compy_rollback_tunnel "$reason"
        COMPY_VERIFY_FAIL_REASON="$reason"
        return 1
    fi
    set +e
    reason="$(compy_verify_full_tunnel "$server_ip" "$expect_ip")"
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        _compy_set compy_last_result "fail: $reason"
        compy_rollback_tunnel "$reason"
        ynh_print_err "Full-tunnel verification failed and the change was rolled back (your Compy should be using the home internet path again; LAN was not moved). ${reason}"
        COMPY_VERIFY_FAIL_REASON="$reason"
        return 1
    fi
    compy_commit_tunnel
    return 0
}

# ---------------------------- result parsing ----------------------------

compy_parse_result() {
    # Reads a captured script output file, sets COMPY_RESULT_* globals.
    local out_file="$1"
    COMPY_RESULT_STATUS="$(awk -F= '/^COMPY_RESULT=/{sub(/^[^=]+=/,""); print}' "$out_file" | tail -1)"
    COMPY_RESULT_ERROR="$(awk -F= '/^COMPY_ERROR=/{sub(/^[^=]+=/,""); print}' "$out_file" | tail -1)"
    COMPY_RESULT_PUBKEY="$(awk -F= '/^COMPY_SERVER_PUBKEY=/{sub(/^[^=]+=/,""); print}' "$out_file" | tail -1)"
    COMPY_RESULT_WG_PORT="$(awk -F= '/^COMPY_ENDPOINT_PORT=/{sub(/^[^=]+=/,""); print}' "$out_file" | tail -1)"
    COMPY_RESULT_SERVER_IP="$(awk -F= '/^COMPY_WG_SERVER_IP=/{sub(/^[^=]+=/,""); print}' "$out_file" | tail -1)"
    COMPY_RESULT_PEER_IP="$(awk -F= '/^COMPY_WG_PEER_IP=/{sub(/^[^=]+=/,""); print}' "$out_file" | tail -1)"
    COMPY_RESULT_SUBNET="$(awk -F= '/^COMPY_WG_SUBNET=/{sub(/^[^=]+=/,""); print}' "$out_file" | tail -1)"
    COMPY_RESULT_PUBLIC_IP="$(awk -F= '/^COMPY_PUBLIC_IP=/{sub(/^[^=]+=/,""); print}' "$out_file" | tail -1)"
}

compy_run_vps_setup() {
    local extra_args=("$@")
    local out rc=0
    out="$(mktemp)"
    set +e
    compy_ssh_script "${extra_args[@]}" >"$out" 2>"${out}.err"
    rc=$?
    set -e
    if [[ -s "${out}.err" ]]; then
        ynh_print_info "VPS script messages:"
        # Trim to a reasonable size for the admin UI.
        tail -n 80 "${out}.err" | while IFS= read -r line; do
            ynh_print_info "  $line"
        done
    fi
    if ! grep -q '^COMPY_RESULT=' "$out"; then
        _compy_set compy_last_result "fail: no COMPY_RESULT in script output (ssh rc=$rc)"
        tail -n 20 "$out" "${out}.err" >/tmp/compy-setup-tail 2>/dev/null || true
        local hint="The VPS may have refused sudo, apt may have failed, or the SSH connection dropped."
        if [[ $rc -eq 124 || $rc -eq 137 ]]; then
            hint="The SSH session timed out. See Tools > Logs. If a log entry stays open, run: sudo systemctl restart yunohost-api"
        fi
        ynh_die --message="The VPS script did not return a COMPY_RESULT line (ssh exit $rc). $hint"
    fi
    compy_parse_result "$out"
    rm -f "$out" "${out}.err"
    if [[ "$COMPY_RESULT_STATUS" != "ok" || "$rc" -ne 0 ]]; then
        _compy_set compy_last_result "fail: ${COMPY_RESULT_ERROR:-unknown} (rc=$rc)"
        ynh_die --message="VPS setup failed: ${COMPY_RESULT_ERROR:-unknown error (exit $rc)}. See Tools > Logs for details."
    fi
    _compy_set compy_last_result "ok"
    _compy_set compy_server_pubkey "$COMPY_RESULT_PUBKEY"
    _compy_set compy_server_ip "$COMPY_RESULT_SERVER_IP"
    _compy_set compy_peer_ip "${COMPY_RESULT_PEER_IP:-}"
    if [[ -n "${COMPY_RESULT_PUBLIC_IP:-}" ]]; then
        _compy_set compy_public_ip "$COMPY_RESULT_PUBLIC_IP"
    fi
}

# ---------------------------- getters ----------------------------

# Custom getters are captured by ynh_app_config_show as YAML under
# "<option>:". A raw line such as "tcp:25,80,443;udp:" is parsed as a
# mapping (the trailing colon) and YunoHost then does setattr(option, key, ...)
# which raises: TextOption object has no field "tcp:25,80...;udp".
# Always return a quoted `value:` so the core treats it as the option value.
_compy_return_value() {
    python3 -c 'import json,sys; sys.stdout.write("value: " + json.dumps(sys.argv[1]) + "\n")' "$1"
}


get__compy_ssh_pubkey() {
    compy_ensure_ssh_key
    _compy_return_value "$(tr -d '\n' <"$COMPY_SSH_PUB")"
}

get__compy_host_fingerprint() {
    _compy_paths
    local body style
    if compy_host_is_pinned 2>/dev/null; then
        style="success"
        body="The SSH host key is pinned for $(_compy_setting compy_vps_host):$(_compy_setting compy_ssh_port). A later change of this fingerprint will be refused."
        if [[ -s "$COMPY_KNOWN_HOSTS" ]]; then
            body="${body}

$(ssh-keygen -lf "$COMPY_KNOWN_HOSTS" 2>/dev/null | sed 's/^/  /' || true)"
        fi
    elif [[ -s "$COMPY_KEYSCAN_PENDING" ]]; then
        style="warning"
        body="Last Test connection fingerprints (NOT pinned yet). Compare these with the provider console, then click Pin host key.

$(compy_fingerprint_text | sed 's/^/  /')"
    else
        style="warning"
        body="SSH host key is not pinned yet. Click Test connection."
    fi
    cat <<EOF
style: ${style}
ask:
  en: |
$(printf '%s\n' "$body" | sed 's/^/    /')
EOF
}

get__compy_ports() {
    local saved
    saved="$(_compy_setting compy_ports || true)"
    if [[ -z "$saved" ]]; then
        saved="$(compy_default_ports)"
        _compy_set compy_ports "$saved"
    fi
    _compy_return_value "$saved"
}

get__compy_ports_preview() {
    local ports
    ports="$(_compy_setting compy_ports || true)"
    [[ -n "$ports" ]] || ports="$(compy_default_ports)"
    cat <<EOF
style: info
ask:
  en: |
    Will be forwarded from the VPS public IP to your Compy's WireGuard address:
    \`${ports}\`

    The VPS SSH port and the WireGuard UDP port are never forwarded. The home SSH port is left out of the default list on purpose.
EOF
}

get__compy_bypass_nets() {
    local saved
    saved="$(_compy_setting compy_bypass_nets || true)"
    if [[ -z "$saved" ]]; then
        saved="$(compy_default_bypass_nets)"
        _compy_set compy_bypass_nets "$saved"
    fi
    _compy_return_value "$saved"
}

# WireGuard's operstate is often "unknown"; use the ip-link flags instead.
_compy_link_is_up() {
    local ifname="${1:-$COMPY_IF}"
    local flags
    flags="$(ip -o link show dev "$ifname" 2>/dev/null || true)"
    [[ -n "$flags" ]] || return 1
    # Flags look like: 4: compy: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 ...
    [[ "$flags" == *"<UP,"* || "$flags" == *",UP,"* || "$flags" == *",UP>"* || "$flags" == *"<UP>"* ]]
}

get__compy_status() {
    _compy_paths
    local style="info"
    local body="The Gate tunnel has not been set up yet."
    local last handshake ping_s="" mode_s="" ip_s="" wd_s=""
    last="$(_compy_setting compy_last_result || true)"
    local server_ip public_ip
    server_ip="$(_compy_setting compy_server_ip || true)"
    public_ip="$(_compy_setting compy_public_ip || true)"

    if [[ -f "$COMPY_CONF" ]]; then
        if grep -q '^AllowedIPs *= *0\.0\.0\.0/0' "$COMPY_CONF"; then
            mode_s=" This is a full-tunnel config: all IPv4 internet should leave through the VPS. LAN, RFC1918, and CGNAT/Starlink subnets stay on the home network."
        else
            mode_s=" The current config is still split-tunnel (only the WireGuard subnet). Re-run Connect and set up the VPS to switch to full tunnel; that step verifies connectivity and rolls back if it fails."
        fi
    fi

    if [[ -f "$install_dir/compy_watchdog_tripped" ]]; then
        style="warning"
        wd_s=" The watchdog stopped The Gate tunnel ($(tr -d '\n' <"$install_dir/compy_watchdog_tripped")). Internet should be back on the home WAN. Start the tunnel again after the VPS is healthy."
    fi

    if [[ -f "$COMPY_CONF" ]] && wg show "$COMPY_IF" >/dev/null 2>&1; then
        handshake="$(wg show "$COMPY_IF" latest-handshakes 2>/dev/null | awk '{print $2; exit}')"
        local link_s="down"
        if _compy_link_is_up "$COMPY_IF"; then
            link_s="up"
        fi
        if [[ "$handshake" =~ ^[0-9]+$ ]] && ((handshake > 0)); then
            local ago=$(( $(date +%s) - handshake ))
            if ((ago < 180)); then
                style="success"
                body="The Gate tunnel (${COMPY_IF}) is ${link_s}. Last handshake ${ago}s ago."
            else
                style="warning"
                body="The Gate tunnel (${COMPY_IF}) is ${link_s}, but the last handshake was ${ago}s ago (WireGuard usually refreshes every ~25s with PersistentKeepalive). The VPS may be unreachable; if this lasts a few minutes the watchdog will take the tunnel down to restore home internet."
            fi
        elif [[ "$link_s" == "up" ]]; then
            style="warning"
            body="The Gate tunnel (${COMPY_IF}) is up, but there is no handshake yet."
        else
            style="warning"
            body="The Gate tunnel (${COMPY_IF}) is configured but the interface is down."
        fi
        if [[ -n "$server_ip" ]] && ping -c 1 -W 2 "$server_ip" >/dev/null 2>&1; then
            ping_s=" Ping to ${server_ip} succeeded."
        elif [[ -n "$server_ip" ]]; then
            ping_s=" Ping to ${server_ip} failed."
        fi
        body="${body}${ping_s}${mode_s}"
        if [[ -n "$public_ip" ]]; then
            ip_s=" Last confirmed public IPv4 (ip.yunohost.org): ${public_ip}."
            body="${body}${ip_s}"
        fi
    else
        body="The Gate tunnel has not been set up yet, or it is stopped.${mode_s}${wd_s}"
    fi
    if [[ -n "$last" ]]; then
        body="${body}

Last setup result: ${last}"
    fi
    cat <<EOF
style: ${style}
ask:
  en: |
$(printf '%s\n' "$body" | sed 's/^/    /')
EOF
}

# ---------------------------- actions ----------------------------

run__compy_regen_ssh_key() {
    _compy_paths
    mkdir -p "$COMPY_SSH_DIR"
    chmod 700 "$COMPY_SSH_DIR"
    rm -f "$COMPY_SSH_KEY" "$COMPY_SSH_PUB"
    compy_ensure_ssh_key
    ynh_print_info "A new SSH key was created. Copy the new public key into the VPS provider panel and remove the old one. The host key pin is unchanged."
}

run__compy_test_ssh() {
    _compy_require_host
    # Persist the form values: the core usually already saved settings for
    # non-null binds when the action runs, but Save is not always clicked.
    # The action section may not include the host fields (they live in
    # [compy.vps]); we rely on saved settings. Ask the admin to Save first
    # if the setting is empty — already handled by _compy_require_host.
    compy_ensure_ssh_key
    compy_keyscan
    ynh_print_info "SSH host fingerprints for ${COMPY_HOST}:${COMPY_SPORT}:"
    local line
    while IFS= read -r line; do
        ynh_print_info "  $line"
    done < <(compy_fingerprint_text)
    ynh_print_info "Compare these with the fingerprint shown in the OVH (or other) console, then click Pin host key."

    if compy_host_is_pinned; then
        ynh_print_info "This host is already pinned. Trying a non-interactive login..."
        # compy_ssh already wraps this in `sudo -n bash -c` (or bash -c as root).
        local probe="id -u && . /etc/os-release && echo COMPY_OS=\$ID \$VERSION_ID"
        local output rc=0
        output="$(compy_ssh "$probe")" || rc=$?
        if [[ $rc -eq 124 ]]; then
            ynh_die --message="SSH to the VPS timed out. See Tools > Logs for details. If a log entry stays open, run: sudo systemctl restart yunohost-api"
        elif [[ $rc -ne 0 ]]; then
            ynh_die --message="Host key is pinned but login or passwordless sudo failed. On OVH Debian, the user is often 'debian' and must have sudo NOPASSWD (cloud-init usually sets this when you install the SSH key). Root login may be disabled. See Tools > Logs for details."
        fi
        ynh_print_info "Login and sudo succeeded. Remote: $output"
    fi
}

run__compy_pin_host() {
    compy_pin_pending_host
}

run__compy_reload_ports() {
    local ports
    ports="$(compy_default_ports)"
    _compy_set compy_ports "$ports"
    ynh_print_info "Reloaded the port list from the YunoHost firewall (safe default, SSH and local-only UDP ports excluded): $ports"
}

run__compy_setup_vps() {
    _compy_require_host
    compy_ensure_ssh_key
    compy_ensure_wg_keys
    compy_host_is_pinned || ynh_die --message="Pin the VPS SSH host key first (Test connection, compare the fingerprint, Pin host key)."

    local ports wg_port wg_subnet peer_pub parsed
    ports="$(_compy_setting compy_ports)"
    wg_port="$(_compy_setting compy_wg_port)"
    wg_subnet="$(_compy_setting compy_wg_subnet)"
    [[ -n "$ports" ]] || ports="$(compy_default_ports)"
    [[ "$wg_port" =~ ^[0-9]+$ ]] || ynh_die --message="WireGuard port is not set."
    [[ -n "$wg_subnet" ]] || ynh_die --message="WireGuard subnet is not set."

    _compy_paths
    peer_pub="$(tr -d '\n' <"$COMPY_WG_PUB")"
    _compy_is_wg_key "$peer_pub" || ynh_die --message="Local WireGuard public key is missing or invalid."

    ynh_print_info "Connecting to ${COMPY_USER}@${COMPY_HOST}:${COMPY_SPORT} and running The Gate setup script on the VPS. This can take a few minutes on a fresh Debian image."
    compy_run_vps_setup \
        --peer-pubkey "$peer_pub" \
        --ports "$ports" \
        --wg-port "$wg_port" \
        --ssh-port "$COMPY_SPORT" \
        --wg-subnet "$wg_subnet"

    local prefixlen
    parsed="$(_compy_second_host "${COMPY_RESULT_SUBNET:-$wg_subnet}")" \
        || ynh_die --message="Could not parse subnet ${COMPY_RESULT_SUBNET:-$wg_subnet}"
    # parsed: first second prefixlen subnet
    local first second
    read -r first second prefixlen _ <<<"$parsed"
    local peer_ip="${COMPY_RESULT_PEER_IP:-$second}"
    local server_ip="${COMPY_RESULT_SERVER_IP:-$first}"
    local subnet="${COMPY_RESULT_SUBNET:-$wg_subnet}"
    local ep_port="${COMPY_RESULT_WG_PORT:-$wg_port}"

    local public_ip="${COMPY_RESULT_PUBLIC_IP:-}"
    ynh_print_info "VPS is ready. Server public key: ${COMPY_RESULT_PUBKEY}. Writing the full-tunnel client config, bringing it up, and verifying that ip.yunohost.org sees the VPS. If that fails, the change is rolled back."
    compy_write_client_conf "$COMPY_RESULT_PUBKEY" "$COMPY_HOST" "$ep_port" "$server_ip" "$peer_ip" "$prefixlen" "$subnet"
    if ! compy_start_and_verify "$server_ip" "$public_ip"; then
        ynh_die --message="Full-tunnel verification failed and the change was rolled back (your Compy should be using the home internet path again; LAN was not moved). The VPS still SNATs inbound DNATed traffic, so an older split-tunnel config keeps working. ${COMPY_VERIFY_FAIL_REASON:-unknown reason} See Tools > Logs for details."
    fi
    # Home is now a verified full tunnel: drop inbound SNAT so YunoHost sees real client IPs.
    ynh_print_info "Tunnel verified. Updating the VPS firewall so visitors' real IPs are visible on your Compy..."
    if ! compy_run_vps_setup \
        --peer-pubkey "$peer_pub" \
        --ports "$ports" \
        --wg-port "$wg_port" \
        --ssh-port "$COMPY_SPORT" \
        --wg-subnet "$wg_subnet" \
        --no-dnat-snat; then
        ynh_print_err "The Gate tunnel is up, but the VPS could not drop inbound SNAT. Visitor IPs may still appear as the gateway address. You can retry Re-sync ports later. See Tools > Logs for details."
    fi
    _compy_set compy_last_result "ok: full tunnel, public IP $(_compy_setting compy_public_ip || true)"
    ynh_print_info "Done. All IPv4 internet from your Compy now leaves through ${COMPY_HOST}. nohost.me DynDNS will auto-detect the VPS IP (no manual dyndns update, no removecron). For a custom domain, point the A record at ${COMPY_HOST} and do not publish an AAAA record. Set a PTR/rDNS record for the VPS in the OVH panel so outbound mail is accepted. If the VPS dies, your Compy loses internet until the watchdog (about 3 minutes) takes the tunnel down or you click Turn tunnel off; LAN and LAN SSH stay reachable."
}

run__compy_resync_ports() {
    _compy_require_host
    compy_host_is_pinned || ynh_die --message="The VPS is not pinned yet. Run the full setup first."
    _compy_paths
    local ports wg_port wg_subnet peer_pub
    ports="$(_compy_setting compy_ports)"
    wg_port="$(_compy_setting compy_wg_port)"
    wg_subnet="$(_compy_setting compy_wg_subnet)"
    peer_pub="$(tr -d '\n' <"$COMPY_WG_PUB")"
    [[ -n "$ports" ]] || ynh_die --message="The port list is empty."
    local snat_flag="--dnat-snat"
    if [[ "$(_compy_setting compy_full_tunnel || true)" == "1" ]] && grep -q '^AllowedIPs *= *0\.0\.0\.0/0' "$COMPY_CONF" 2>/dev/null; then
        snat_flag="--no-dnat-snat"
    fi
    ynh_print_info "Re-syncing ports on ${COMPY_HOST}: $ports (${snat_flag})"
    compy_run_vps_setup \
        --peer-pubkey "$peer_pub" \
        --ports "$ports" \
        --wg-port "$wg_port" \
        --ssh-port "$COMPY_SPORT" \
        --wg-subnet "$wg_subnet" \
        "$snat_flag"
    ynh_print_info "Port list re-applied on the VPS."
}

run__compy_test_ports() {
    _compy_require_host
    _compy_paths
    local server_ip ports
    server_ip="$(_compy_setting compy_server_ip || true)"
    ports="$(_compy_setting compy_ports)"

    if [[ -n "$server_ip" ]]; then
        if ping -c 3 -W 3 "$server_ip" >/dev/null 2>&1; then
            ynh_print_info "Tunnel ping to ${server_ip} succeeded."
        else
            ynh_print_err "Tunnel ping to ${server_ip} failed."
        fi
    fi
    if wg show "$COMPY_IF" latest-handshakes >/dev/null 2>&1; then
        ynh_print_info "wg show ${COMPY_IF} latest-handshakes:"
        ynh_print_info "  $(wg show "$COMPY_IF" latest-handshakes 2>/dev/null)"
    fi

    # diagnosis.yunohost.org probes the SOURCE IP of the request. With the
    # full tunnel up that is the VPS public IP, so official
    # `yunohost diagnosis run ports` from this box should work. We still
    # also POST the check from the VPS so the probe works even if the
    # tunnel is down (DNAT on the VPS remains).
    local tcp_list
    tcp_list="$(printf '%s' "$ports" | awk -F';' '{
        for (i=1;i<=NF;i++) if ($i ~ /^tcp:/) { sub(/^tcp:/, "", $i); print $i }
    }')"
    # The official checker is TCP-only (issue #1914). Expand ranges in python.
    local json_ports
    json_ports="$(python3 -c '
import sys
raw = sys.argv[1].strip()
ports = []
for tok in raw.split(","):
    tok = tok.strip()
    if not tok:
        continue
    if "-" in tok:
        a, b = tok.split("-", 1)
        for p in range(int(a), int(b)+1):
            ports.append(p)
    else:
        ports.append(int(tok))
# Cap the request size; the public checker may refuse huge lists.
ports = ports[:40]
print("[" + ",".join(str(p) for p in ports) + "]")
' "$tcp_list")"

    if [[ "$json_ports" == "[]" ]]; then
        ynh_print_info "No TCP ports to probe."
        return 0
    fi

    ynh_print_info "Asking https://${COMPY_DIAGNOSIS_SERVER}/check-ports to probe the VPS (request sent from the VPS) for TCP $json_ports ..."
    local remote_py
    remote_py=$(cat <<EOF
python3 -c 'import json,sys,urllib.request
req=urllib.request.Request("https://${COMPY_DIAGNOSIS_SERVER}/check-ports", data=json.dumps({"ports": ${json_ports}}).encode(), headers={"Content-Type":"application/json"}, method="POST")
try:
    with urllib.request.urlopen(req, timeout=45) as r:
        sys.stdout.write(r.read().decode())
except Exception as e:
    sys.stderr.write("check-ports failed: %s\n" % e)
    sys.exit(2)
'
EOF
)
    # python3 may not be installed on a minimal Debian VPS. Install it on
    # demand (slow but rare) or use curl. Prefer curl if present.
    local probe_cmd
    probe_cmd="if command -v curl >/dev/null; then curl -fsS --max-time 45 -X POST https://${COMPY_DIAGNOSIS_SERVER}/check-ports -H 'Content-Type: application/json' -d '{\"ports\": ${json_ports}}'; elif command -v python3 >/dev/null; then ${remote_py}; else echo 'COMPY_PROBE_MISSING=1' >&2; exit 3; fi"
    local result rc=0
    result="$(compy_ssh "$probe_cmd")" || rc=$?
    if [[ $rc -eq 124 ]]; then
        ynh_die --message="The public port probe on the VPS timed out. See Tools > Logs for details. If a log entry stays open, run: sudo systemctl restart yunohost-api"
    elif [[ $rc -ne 0 ]]; then
        ynh_die --message="Could not run the public port probe from the VPS. Install curl or python3 on the VPS, or check SSH/sudo. See Tools > Logs for details. You can also run: yunohost diagnosis run web --force after pointing DNS at the VPS (the web diagnoser looks up the domain name, unlike the ports diagnoser)."
    fi
    ynh_print_info "Raw probe result: $result"
    python3 -c '
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception:
    print("Could not parse JSON from the diagnosis server.")
    sys.exit(0)
ports = data.get("ports") or data
if not isinstance(ports, dict):
    print("Unexpected response: %s" % raw)
    sys.exit(0)
ok = [p for p, v in ports.items() if v is True]
bad = [p for p, v in ports.items() if v is not True]
if ok:
    print("Reachable: " + ", ".join(str(p) for p in ok))
if bad:
    print("NOT reachable: " + ", ".join(str(p) for p in bad))
    print("If the tunnel is up, check the VPS provider firewall (those TCP ports must be allowed to the VPS), and that YunoHost is listening on them at home.")
' "$result" | while IFS= read -r line; do
        ynh_print_info "$line"
    done

    # With the full tunnel, a request from this box to diagnosis.yunohost.org
    # should now come from the VPS public IP, so official
    # `yunohost diagnosis run ports` is meaningful. Still also probe from the
    # VPS above in case the tunnel is down.
    local seen=""
    if command -v curl >/dev/null 2>&1; then
        seen="$(curl -4 -fsS --max-time 10 https://ip.yunohost.org 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    if [[ -n "$seen" ]]; then
        ynh_print_info "This box's public IPv4 (https://ip.yunohost.org) is currently ${seen}."
    fi
    ynh_print_info "With the full tunnel up, official 'yunohost diagnosis run ports' and 'yunohost diagnosis run web --force' from this box should see the VPS IP (this button does not start those itself). nohost.me DynDNS auto-detects that address. For a custom domain, point the A record at the VPS (no AAAA)."
}

# Optional validators (echo a message to fail; echo nothing to pass).
validate__compy_wg_subnet() {
    python3 -c '
import sys, ipaddress
try:
    n = ipaddress.ip_network(sys.argv[1], strict=False)
except Exception:
    print("Not a valid IPv4 CIDR")
    sys.exit(0)
if n.version != 4:
    print("Only IPv4 subnets are supported in this version")
elif not (16 <= n.prefixlen <= 30):
    print("Prefix must be between /16 and /30")
' "${compy_wg_subnet:-}"
}

validate__compy_ports() {
    python3 -c '
import re, sys
raw = (sys.argv[1] or "").replace(" ", "")
if not raw:
    print("Port list is empty")
    sys.exit(0)
for chunk in raw.split(";"):
    if not chunk:
        continue
    if ":" not in chunk:
        print("Each part must look like tcp:80,443 or udp:500")
        sys.exit(0)
    proto, lst = chunk.split(":", 1)
    if proto not in ("tcp", "udp"):
        print("Protocol must be tcp or udp")
        sys.exit(0)
    if not lst:
        continue
    for tok in lst.split(","):
        if not tok:
            continue
        if not re.match(r"^[0-9]+(-[0-9]+)?$", tok):
            print("Invalid port or range: %s" % tok)
            sys.exit(0)
' "${compy_ports:-}"
}

validate__compy_bypass_nets() {
    python3 -c '
import sys, ipaddress
raw = sys.argv[1] or ""
if not raw.strip():
    print("Enter at least one IPv4 CIDR, or reload the default list")
    sys.exit(0)
for tok in raw.replace(";", ",").split(","):
    tok = tok.strip()
    if not tok or tok.startswith("#"):
        continue
    try:
        net = ipaddress.ip_network(tok, strict=False)
    except Exception:
        print("Not a valid IPv4 CIDR: %s" % tok)
        sys.exit(0)
    if net.version != 4:
        print("Only IPv4 CIDRs are supported in this version: %s" % tok)
        sys.exit(0)
    if net.prefixlen == 0:
        print("0.0.0.0/0 cannot be excluded: that would disable the tunnel default route")
        sys.exit(0)
' "${compy_bypass_nets:-}"
}

run__compy_tunnel_off() {
    _compy_paths
    ynh_print_info "Stopping The Gate tunnel. IPv4 internet will use the home WAN again. LAN access is unchanged. The VPS is left running; public access through it will stop until you start the tunnel again."
    compy_disable_watchdog
    compy_stop_tunnel
    systemctl disable --quiet "wireguard_client@${COMPY_IF}.service" 2>/dev/null || true
    ynh_app_setting_set --key="${COMPY_IF}_atboot" --value=0
    _compy_set compy_last_result "tunnel stopped by emergency off"
    ynh_print_info "The Gate tunnel is stopped. Use Start the tunnel when you want to go back through the VPS (that step is verified and rolled back on failure)."
}

run__compy_tunnel_on() {
    _compy_paths
    [[ -f "$COMPY_CONF" ]] || ynh_die --message="The Gate tunnel has no saved config yet. Run Connect and set up the VPS first."
    local server_ip public_ip
    server_ip="$(_compy_setting compy_server_ip || true)"
    public_ip="$(_compy_setting compy_public_ip || true)"
    [[ -n "$server_ip" ]] || ynh_die --message="The VPS tunnel address is not stored yet. Run Connect and set up the VPS first."
    ynh_print_info "Starting The Gate tunnel and verifying that your Compy's public IPv4 becomes the VPS address."
    if ! compy_start_and_verify "$server_ip" "$public_ip"; then
        ynh_die --message="Full-tunnel verification failed and the change was rolled back (your Compy should be using the home internet path again; LAN was not moved). ${COMPY_VERIFY_FAIL_REASON:-unknown reason} See Tools > Logs for details."
    fi
    _compy_set compy_last_result "ok: tunnel started, public IP $(_compy_setting compy_public_ip || true)"
    ynh_print_info "The Gate tunnel is up and verified."
}
