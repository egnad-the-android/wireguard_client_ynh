#!/usr/bin/env bash
# Compy Level 2 — VPS WireGuard server + strict DNAT gateway
# Untested on a real VPS. Intended for a plain minimal Debian VPS (e.g. OVH $5).
#
# This VPS has no web server, no Caddy, no TLS termination, and no web UI.
# TLS stays on the home YunoHost box. This script only:
#   - installs WireGuard and nftables
#   - creates a WG server (keys are never silently regenerated)
#   - DNATs a supplied TCP/UDP port list to the home peer's WG address
#   - SNATs those DNATed packets so replies return through the tunnel
#   - keeps SSH and the WG UDP port open; drop-by-default for other input
#
# Run from the home YunoHost server, typically:
#   ssh -i KEY -p PORT -o BatchMode=yes -o StrictHostKeyChecking=yes \
#       USER@VPS 'sudo -n bash -s -- --peer-pubkey ... --ports ...' < vps_setup.sh
#
# Or copied to the VPS as /usr/local/sbin/compy-vps-setup and re-run there.
#
# Last lines of stdout are machine-readable:
#   COMPY_RESULT=ok
#   COMPY_SERVER_PUBKEY=...
#   COMPY_ENDPOINT_PORT=51820
#   COMPY_WG_SERVER_IP=10.99.0.1
#   COMPY_WG_PEER_IP=10.99.0.2
#   COMPY_WG_SUBNET=10.99.0.0/24
# or:
#   COMPY_RESULT=fail
#   COMPY_ERROR=...
# Nonzero exit on failure. Full log: /var/log/compy-vps-setup.log
#
# Default NAT policy (v1): SNAT DNATed traffic toward the home peer
# (source becomes the WG server address). Visitor IPs are hidden from
# the home box (fail2ban / mail logs see the gateway). See REPORT.md.

set -u
# set -e is applied after the fail-trap helpers are in place, via a
# controlled runner, so COMPY_RESULT=fail is always printed.

umask 077

COMPY_DIR="/etc/compy"
COMPY_LOG="/var/log/compy-vps-setup.log"
COMPY_NFT="${COMPY_DIR}/compy.nft"
COMPY_PORTS_FILE="${COMPY_DIR}/ports.list"
COMPY_STATE="${COMPY_DIR}/state"
WG_DIR="/etc/wireguard"
WG_IF="wg0"
WG_CONF="${WG_DIR}/${WG_IF}.conf"
SERVER_KEY="${COMPY_DIR}/wg-server.key"
SERVER_PUB="${COMPY_DIR}/wg-server.pub"
SYSCTL_FILE="/etc/sysctl.d/99-compy-forward.conf"
SELF_INSTALL="/usr/local/sbin/compy-vps-setup"

# Defaults
PEER_PUBKEY=""
PORTS_ARG=""
WG_PORT="51820"
SSH_PORT="22"
WG_SUBNET="10.99.0.0/24"
PUBLIC_IF=""
UNINSTALL=0
PURGE=0

# Log file is created in main() once we know we are root and not just --help.

# Timestamped log, plus a copy of every line we also want on stdout later.
log() {
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    if [[ -w "$COMPY_LOG" ]] || [[ -w "$(dirname "$COMPY_LOG")" ]]; then
        printf '%s %s\n' "$ts" "$*" >>"$COMPY_LOG" 2>/dev/null || true
    fi
}

# Human messages go to stderr (and the log) so stdout stays parseable.
msg() {
    log "$*"
    printf '%s\n' "$*" >&2
}

emit() {
    # Machine-readable line: stdout + log.
    log "$*"
    printf '%s\n' "$*"
}

fail() {
    local err="${1:-unknown error}"
    # Flatten newlines so COMPY_ERROR stays one line.
    err="${err//$'\n'/ }"
    emit "COMPY_RESULT=fail"
    emit "COMPY_ERROR=${err}"
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage: compy-vps-setup [options]

  --peer-pubkey KEY   Home YunoHost WireGuard public key (required except --uninstall)
  --ports LIST        tcp:25,80,443,587;udp:   (required except --uninstall;
                      on re-run, omitted LIST is re-read from /etc/compy/ports.list)
  --wg-port N         WireGuard listen port (default 51820)
  --ssh-port N        SSH port to keep open on this VPS (default 22)
  --wg-subnet CIDR    Tunnel subnet (default 10.99.0.0/24). Server = first host, peer = second.
  --public-if IFACE   Public interface (auto-detected from the IPv4 default route)
  --uninstall         Stop WG, remove the nftables table and boot units. Keys are kept.
  --purge             With --uninstall, also delete keys and /etc/compy
  -h, --help          Show this help
EOF
}

# ---------------------------- argument parsing ----------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --peer-pubkey)
            [[ $# -ge 2 ]] || fail "missing value for --peer-pubkey"
            PEER_PUBKEY="$2"; shift 2 ;;
        --ports)
            [[ $# -ge 2 ]] || fail "missing value for --ports"
            PORTS_ARG="$2"; shift 2 ;;
        --wg-port)
            [[ $# -ge 2 ]] || fail "missing value for --wg-port"
            WG_PORT="$2"; shift 2 ;;
        --ssh-port)
            [[ $# -ge 2 ]] || fail "missing value for --ssh-port"
            SSH_PORT="$2"; shift 2 ;;
        --wg-subnet)
            [[ $# -ge 2 ]] || fail "missing value for --wg-subnet"
            WG_SUBNET="$2"; shift 2 ;;
        --public-if)
            [[ $# -ge 2 ]] || fail "missing value for --public-if"
            PUBLIC_IF="$2"; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        --purge)     PURGE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           fail "unknown argument: $1" ;;
    esac
done

# ---------------------------- helpers ----------------------------

is_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && ((p >= 1 && p <= 65535))
}

is_port_or_range() {
    local p="$1"
    if [[ "$p" =~ ^[0-9]+$ ]]; then
        is_port "$p"
        return
    fi
    if [[ "$p" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        is_port "${BASH_REMATCH[1]}" && is_port "${BASH_REMATCH[2]}" && ((BASH_REMATCH[1] <= BASH_REMATCH[2]))
        return
    fi
    return 1
}

# Return 0 if a single port or any port in a range equals $2.
port_covers() {
    local token="$1" target="$2"
    if [[ "$token" =~ ^[0-9]+$ ]]; then
        [[ "$token" == "$target" ]]
        return
    fi
    if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        ((target >= BASH_REMATCH[1] && target <= BASH_REMATCH[2]))
        return
    fi
    return 1
}

# Parse "tcp:25,80,443-445;udp:500" into global arrays TCP_PORTS and UDP_PORTS.
# Accepts also "25,80/tcp" leftovers? No, stick to the documented format.
# Spaces are ignored. Empty proto lists are allowed.
parse_ports() {
    local raw="${1// /}"
    TCP_PORTS=()
    UDP_PORTS=()
    [[ -n "$raw" ]] || return 0

    local -a chunks=()
    IFS=';' read -r -a chunks <<<"$raw"
    local chunk proto list item
    for chunk in "${chunks[@]}"; do
        [[ -n "$chunk" ]] || continue
        if [[ "$chunk" != *:* ]]; then
            fail "port list item '$chunk' must look like tcp:80,443 or udp:500"
        fi
        proto="${chunk%%:*}"
        list="${chunk#*:}"
        proto="${proto,,}"
        [[ "$proto" == "tcp" || "$proto" == "udp" ]] || fail "unknown protocol '$proto' (use tcp or udp)"
        [[ -n "$list" ]] || continue
        local -a items=()
        IFS=',' read -r -a items <<<"$list"
        for item in "${items[@]}"; do
            [[ -n "$item" ]] || continue
            is_port_or_range "$item" || fail "invalid port or range '$item'"
            if [[ "$proto" == "tcp" ]]; then
                TCP_PORTS+=("$item")
            else
                UDP_PORTS+=("$item")
            fi
        done
    done
}

ports_to_canonical() {
    local out=""
    if ((${#TCP_PORTS[@]})); then
        local IFS=','
        out="tcp:${TCP_PORTS[*]}"
    else
        out="tcp:"
    fi
    if ((${#UDP_PORTS[@]})); then
        local IFS=','
        out="${out};udp:${UDP_PORTS[*]}"
    else
        out="${out};udp:"
    fi
    printf '%s' "$out"
}

# IPv4 dotted-quad <-> unsigned int
ip_to_int() {
    local -a o=()
    IFS=. read -r -a o <<<"$1"
    ((${#o[@]} == 4)) || return 1
    local i
    for i in "${o[@]}"; do
        [[ "$i" =~ ^[0-9]+$ ]] && ((i >= 0 && i <= 255)) || return 1
    done
    printf '%u' $(( (o[0] << 24) + (o[1] << 16) + (o[2] << 8) + o[3] ))
}

int_to_ip() {
    local n="$1"
    printf '%d.%d.%d.%d' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) $(( (n >> 8) & 255 )) $(( n & 255 ))
}

# Normalize --wg-subnet (network or address + prefix) into:
#   SUBNET_CIDR, SERVER_IP, PEER_IP, PREFIXLEN
parse_subnet() {
    local spec="$1"
    [[ "$spec" =~ ^([0-9.]+)/([0-9]+)$ ]] || fail "invalid --wg-subnet '$spec' (expected CIDR like 10.99.0.0/24)"
    local addr="${BASH_REMATCH[1]}"
    PREFIXLEN="${BASH_REMATCH[2]}"
    if [[ ! "$PREFIXLEN" =~ ^[0-9]+$ ]] || ((PREFIXLEN < 16 || PREFIXLEN > 30)); then
        fail "--wg-subnet prefix must be between /16 and /30 (got /$PREFIXLEN)"
    fi
    local addr_int mask net
    addr_int="$(ip_to_int "$addr")" || fail "invalid IPv4 address in --wg-subnet: $addr"
    mask=$(( (0xFFFFFFFF << (32 - PREFIXLEN)) & 0xFFFFFFFF ))
    # bash arithmetic on 32-bit may sign-extend; mask with 2^32-1 via printf
    net=$(( addr_int & mask ))
    # Force unsigned
    net="$(printf '%u' $(( net & 0xFFFFFFFF )) )"
    local bcast=$(( net | (0xFFFFFFFF ^ mask) ))
    local first=$(( net + 1 ))
    local second=$(( net + 2 ))
    (( second < bcast )) || fail "--wg-subnet $spec has fewer than two host addresses"
    SERVER_IP="$(int_to_ip "$first")"
    PEER_IP="$(int_to_ip "$second")"
    SUBNET_CIDR="$(int_to_ip "$net")/${PREFIXLEN}"
}

is_wg_key() {
    # Standard WireGuard keys are 32 bytes base64 (44 chars, ending with =).
    [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

need_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi
    fail "this script must run as root (try: sudo -n bash -s -- ...)"
}

detect_public_if() {
    local iface
    iface="$(ip -4 route show default 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    [[ -n "$iface" ]] || fail "could not auto-detect the public interface (pass --public-if)"
    printf '%s' "$iface"
}

check_debian() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    else
        fail "cannot read /etc/os-release"
    fi
    case "${ID:-}" in
        debian)
            case "${VERSION_ID:-}" in
                11|12|13|14) msg "Detected Debian ${VERSION_ID}" ;;
                *) msg "WARNING: Debian ${VERSION_ID:-unknown} is not in the tested list (11-14). Continuing." ;;
            esac
            ;;
        ubuntu)
            msg "WARNING: this script is written for Debian. Ubuntu ${VERSION_ID:-?} may work but is untested."
            ;;
        *)
            fail "unsupported OS '${ID:-unknown}'. This script expects plain Debian."
            ;;
    esac
}

# Refuse to DNAT the VPS SSH port or the WG listen port (would black-hole admin access).
validate_ports_against_reserved() {
    local token
    for token in "${TCP_PORTS[@]}"; do
        if port_covers "$token" "$SSH_PORT"; then
            fail "refusing to DNAT TCP port $SSH_PORT: that is the SSH port of this VPS (pass a different --ssh-port or remove it from --ports)"
        fi
        if port_covers "$token" "$WG_PORT"; then
            fail "refusing to DNAT TCP port $WG_PORT: that is the WireGuard listen port"
        fi
    done
    for token in "${UDP_PORTS[@]}"; do
        if port_covers "$token" "$WG_PORT"; then
            fail "refusing to DNAT UDP port $WG_PORT: that is the WireGuard listen port"
        fi
        if port_covers "$token" "$SSH_PORT"; then
            # Unusual, but possible if someone listed the SSH port under udp.
            fail "refusing to DNAT UDP port $SSH_PORT: that matches --ssh-port"
        fi
    done
}

# If we were launched over SSH, the server-side port should match --ssh-port.
warn_or_fail_ssh_session_port() {
    local sess="${SSH_CONNECTION:-}"
    [[ -n "$sess" ]] || return 0
    local dest_port
    dest_port="$(awk '{print $4}' <<<"$sess")"
    if [[ -n "$dest_port" && "$dest_port" != "$SSH_PORT" ]]; then
        fail "this SSH session is on port $dest_port but --ssh-port is $SSH_PORT; refusing to install a drop-by-default input chain that would lock you out"
    fi
}

nft_list_csv() {
    # Join port tokens for an nftables set/range list: { 80, 443, 1000-2000 }
    local -a items=("$@")
    ((${#items[@]})) || { printf ''; return 0; }
    local IFS=', '
    printf '%s' "${items[*]}"
}

write_nft_rules() {
    local tcp_csv udp_csv
    tcp_csv="$(nft_list_csv "${TCP_PORTS[@]+"${TCP_PORTS[@]}"}")"
    udp_csv="$(nft_list_csv "${UDP_PORTS[@]+"${UDP_PORTS[@]}"}")"

    mkdir -p "$COMPY_DIR"
    # The file must not "flush ruleset". It only (re)defines table ip compy.
    cat >"$COMPY_NFT" <<EOF
# Generated by compy-vps-setup. Do not edit; re-run the script.
# table ip = IPv4 only. IPv6 is out of scope for Compy Level 2 v1.

table ip compy {
    chain input {
        type filter hook input priority filter; policy accept;
        ct state established,related accept
        iifname "lo" accept
        tcp dport ${SSH_PORT} accept
        udp dport ${WG_PORT} accept
        icmp type echo-request accept
        # DHCP client renewals on the public interface (OVH may use DHCP).
        udp sport 67 udp dport 68 accept
        counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
        ct state established,related accept
$(if [[ -n "$tcp_csv" ]]; then
    printf '        iifname "%s" oifname "%s" ip daddr %s tcp dport { %s } accept\n' "$PUBLIC_IF" "$WG_IF" "$PEER_IP" "$tcp_csv"
fi)
$(if [[ -n "$udp_csv" ]]; then
    printf '        iifname "%s" oifname "%s" ip daddr %s udp dport { %s } accept\n' "$PUBLIC_IF" "$WG_IF" "$PEER_IP" "$udp_csv"
fi)
        counter drop
    }

    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
$(if [[ -n "$tcp_csv" ]]; then
    printf '        iifname "%s" tcp dport { %s } dnat to %s\n' "$PUBLIC_IF" "$tcp_csv" "$PEER_IP"
fi)
$(if [[ -n "$udp_csv" ]]; then
    printf '        iifname "%s" udp dport { %s } dnat to %s\n' "$PUBLIC_IF" "$udp_csv" "$PEER_IP"
fi)
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # Only SNAT packets that were DNATed, going toward the home peer.
        # Home then sees source ${SERVER_IP}, so replies match AllowedIPs
        # and return through wg0. Visitor IPs are not visible on the home box.
        oifname "${WG_IF}" ip daddr ${PEER_IP} ct status dnat snat to ${SERVER_IP}
    }
}
EOF
    chmod 600 "$COMPY_NFT"
}

apply_nft_rules() {
    write_nft_rules
    if nft list table ip compy >/dev/null 2>&1; then
        nft delete table ip compy || fail "failed to delete the previous nftables table ip compy"
    fi
    nft -f "$COMPY_NFT" || fail "nft -f $COMPY_NFT failed; see $COMPY_LOG and the file contents"

    # Persist across reboot. Debian's /etc/nftables.conf starts with "flush ruleset".
    ensure_nftables_include
    systemctl enable nftables.service >/dev/null 2>&1 || true
    # Do not systemctl restart nftables here: that flushes the live ruleset and
    # would drop this SSH session if anything goes wrong mid-reload. enable is
    # enough; our table is already live. On boot, nftables.service loads the include.
}

ensure_nftables_include() {
    local nft_conf="/etc/nftables.conf"
    local include_line='include "/etc/compy/compy.nft"'
    if [[ ! -f "$nft_conf" ]]; then
        cat >"$nft_conf" <<EOF
#!/usr/sbin/nft -f
flush ruleset
${include_line}
EOF
        return 0
    fi
    if grep -qF "$include_line" "$nft_conf"; then
        return 0
    fi
    cp -a "$nft_conf" "${nft_conf}.compy-bak"
    printf '\n# Compy Level 2 persistence\n%s\n' "$include_line" >>"$nft_conf"
}

ensure_ip_forward() {
    cat >"$SYSCTL_FILE" <<'EOF'
# Compy Level 2: required for DNAT/forward of public ports to the WG peer.
net.ipv4.ip_forward=1
EOF
    chmod 644 "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" >/dev/null || fail "failed to enable net.ipv4.ip_forward"
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    msg "Installing wireguard and nftables (apt)..."
    apt-get update -y >>"$COMPY_LOG" 2>&1 || fail "apt-get update failed (see $COMPY_LOG)"
    apt-get install -y wireguard wireguard-tools nftables >>"$COMPY_LOG" 2>&1 \
        || fail "apt-get install wireguard nftables failed (see $COMPY_LOG)"
}

ensure_wg_module() {
    if [[ -d /sys/module/wireguard ]]; then
        return 0
    fi
    if modprobe wireguard >>"$COMPY_LOG" 2>&1; then
        return 0
    fi
    fail "the wireguard kernel module is not available (modprobe failed). Use a Debian kernel 5.6 or later, or install wireguard-dkms and headers."
}

ensure_server_keys() {
    mkdir -p "$COMPY_DIR" "$WG_DIR"
    chmod 700 "$COMPY_DIR" "$WG_DIR"
    if [[ -f "$SERVER_KEY" ]]; then
        msg "Reusing existing WireGuard server key in $SERVER_KEY (never silently regenerated)."
    else
        msg "Generating a new WireGuard server keypair."
        wg genkey >"$SERVER_KEY"
        chmod 600 "$SERVER_KEY"
    fi
    wg pubkey <"$SERVER_KEY" >"$SERVER_PUB"
    chmod 644 "$SERVER_PUB"
    SERVER_PUBKEY="$(tr -d '\n' <"$SERVER_PUB")"
    is_wg_key "$SERVER_PUBKEY" || fail "generated/existing server public key looks invalid"
}

write_wg_conf() {
    local key
    key="$(tr -d '\n' <"$SERVER_KEY")"
    # Do not put PostUp/PostDown here: nftables is managed separately so
    # port re-sync does not require bouncing the tunnel.
    cat >"$WG_CONF" <<EOF
[Interface]
Address = ${SERVER_IP}/${PREFIXLEN}
ListenPort = ${WG_PORT}
PrivateKey = ${key}

[Peer]
PublicKey = ${PEER_PUBKEY}
AllowedIPs = ${PEER_IP}/32
EOF
    chmod 600 "$WG_CONF"
}

start_wg() {
    systemctl enable "wg-quick@${WG_IF}" >>"$COMPY_LOG" 2>&1 || fail "systemctl enable wg-quick@${WG_IF} failed"
    # If already running, reload the conf (peer key / port / address may have changed).
    if systemctl is-active --quiet "wg-quick@${WG_IF}"; then
        # wg syncconf cannot change Address/ListenPort in all cases; bounce safely.
        # The SSH session is on the public interface, not wg0, so this is OK.
        systemctl restart "wg-quick@${WG_IF}" >>"$COMPY_LOG" 2>&1 || fail "failed to restart wg-quick@${WG_IF} (see $COMPY_LOG)"
    else
        systemctl start "wg-quick@${WG_IF}" >>"$COMPY_LOG" 2>&1 || fail "failed to start wg-quick@${WG_IF} (see $COMPY_LOG)"
    fi
}

install_self() {
    # Keep a copy on the VPS so re-sync / uninstall can run without a stdin upload,
    # and so a later command=-restricted SSH key can call a fixed path.
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        cp -f "${BASH_SOURCE[0]}" "$SELF_INSTALL" 2>/dev/null || true
    fi
    # When launched via `bash -s`, BASH_SOURCE may be empty or /dev/fd — skip quietly.
    if [[ -x "$SELF_INSTALL" || -f "$SELF_INSTALL" ]]; then
        chmod 700 "$SELF_INSTALL" || true
    fi
}

save_state() {
    cat >"$COMPY_STATE" <<EOF
WG_PORT=${WG_PORT}
SSH_PORT=${SSH_PORT}
WG_SUBNET=${SUBNET_CIDR}
PUBLIC_IF=${PUBLIC_IF}
SERVER_IP=${SERVER_IP}
PEER_IP=${PEER_IP}
PEER_PUBKEY=${PEER_PUBKEY}
EOF
    chmod 600 "$COMPY_STATE"
    ports_to_canonical >"$COMPY_PORTS_FILE"
    chmod 600 "$COMPY_PORTS_FILE"
}

do_uninstall() {
    msg "Uninstalling Compy gateway (WG + nftables table). uninstall=$UNINSTALL purge=$PURGE"
    systemctl disable --now "wg-quick@${WG_IF}" >>"$COMPY_LOG" 2>&1 || true
    if nft list table ip compy >/dev/null 2>&1; then
        nft delete table ip compy || msg "WARNING: could not delete table ip compy"
    fi
    if [[ -f /etc/nftables.conf ]]; then
        # Leave the include line if the file still exists; remove the include if purging.
        if [[ "$PURGE" -eq 1 ]]; then
            sed -i '/# Compy Level 2 persistence/d;/include "\/etc\/compy\/compy.nft"/d' /etc/nftables.conf || true
        fi
    fi
    rm -f "$WG_CONF"
    if [[ "$PURGE" -eq 1 ]]; then
        rm -rf "$COMPY_DIR" "$SELF_INSTALL" "$SYSCTL_FILE"
        msg "Purged keys and $COMPY_DIR."
    else
        msg "Left keys and $COMPY_DIR in place (pass --purge to delete them)."
    fi
    emit "COMPY_RESULT=ok"
    emit "COMPY_SERVER_PUBKEY="
    emit "COMPY_ENDPOINT_PORT="
    emit "COMPY_WG_SERVER_IP="
    exit 0
}

# ---------------------------- main ----------------------------

main() {
    need_root
    mkdir -p "$(dirname "$COMPY_LOG")"
    touch "$COMPY_LOG"
    chmod 600 "$COMPY_LOG"
    exec 3>>"$COMPY_LOG"
    # Also append a transcript of stderr to the log without losing the terminal.
    exec 2> >(tee -a "$COMPY_LOG" >&2)

    msg "=== Compy VPS setup starting (pid=$$) ==="
    check_debian

    is_port "$WG_PORT"  || fail "invalid --wg-port '$WG_PORT'"
    is_port "$SSH_PORT" || fail "invalid --ssh-port '$SSH_PORT'"
    warn_or_fail_ssh_session_port

    if [[ "$UNINSTALL" -eq 1 ]]; then
        do_uninstall
    fi

    parse_subnet "$WG_SUBNET"
    msg "Tunnel subnet ${SUBNET_CIDR}; server ${SERVER_IP}; home peer ${PEER_IP}"

    if [[ -z "$PUBLIC_IF" ]]; then
        PUBLIC_IF="$(detect_public_if)"
    fi
    ip link show "$PUBLIC_IF" >/dev/null 2>&1 || fail "public interface '$PUBLIC_IF' does not exist"
    msg "Public interface: $PUBLIC_IF"

    if [[ -z "$PEER_PUBKEY" ]]; then
        fail "--peer-pubkey is required"
    fi
    is_wg_key "$PEER_PUBKEY" || fail "invalid --peer-pubkey (expected a 44-character base64 WireGuard key)"

    if [[ -z "$PORTS_ARG" ]]; then
        if [[ -f "$COMPY_PORTS_FILE" ]]; then
            PORTS_ARG="$(tr -d '\n' <"$COMPY_PORTS_FILE")"
            msg "Re-using ports from $COMPY_PORTS_FILE: $PORTS_ARG"
        else
            fail "--ports is required on the first run"
        fi
    fi
    parse_ports "$PORTS_ARG"
    validate_ports_against_reserved
    msg "Port list: $(ports_to_canonical)"

    install_packages
    ensure_wg_module
    ensure_ip_forward
    ensure_server_keys
    write_wg_conf
    start_wg
    apply_nft_rules
    save_state
    install_self

    # Best-effort handshake wait is done on the home side; the home peer
    # may not be up yet when this script finishes.
    emit "COMPY_RESULT=ok"
    emit "COMPY_SERVER_PUBKEY=${SERVER_PUBKEY}"
    emit "COMPY_ENDPOINT_PORT=${WG_PORT}"
    emit "COMPY_WG_SERVER_IP=${SERVER_IP}"
    emit "COMPY_WG_PEER_IP=${PEER_IP}"
    emit "COMPY_WG_SUBNET=${SUBNET_CIDR}"
    msg "=== Compy VPS setup finished successfully ==="
}

main "$@"
