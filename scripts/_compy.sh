#!/bin/bash
# Compy Level 2 helpers for wireguard_client_ynh.
# Sourced from scripts/config, scripts/install, and scripts/upgrade.
# Untested on a real YunoHost server.
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
    if ! ssh-keyscan -4 -T 10 -p "$COMPY_SPORT" -t "ed25519,rsa,ecdsa" "$COMPY_HOST" >"$tmp" 2>/dev/null; then
        rm -f "$tmp"
        ynh_die --message="Could not reach ${COMPY_HOST} port ${COMPY_SPORT} with ssh-keyscan. Check the IP, the SSH port, and the OVH (or other) firewall."
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
compy_ssh() {
    _compy_paths
    _compy_require_host
    compy_ensure_ssh_key
    compy_ssh_base_opts
    compy_host_is_pinned || ynh_die --message="The VPS SSH host key is not pinned yet. Click Test connection, check the fingerprint against the provider console, then click Pin host key."
    local remote_cmd="$1"
    local sudo_cmd
    if [[ "$COMPY_USER" == "root" ]]; then
        sudo_cmd="$remote_cmd"
    else
        # -n: never prompt for a password. Fail clearly if sudo is not passwordless.
        sudo_cmd="sudo -n -- $remote_cmd"
    fi
    # The remaining positional args after $1 are not used; stdin is passed through.
    ssh "${COMPY_SSH_OPTS[@]}" \
        -o "StrictHostKeyChecking=yes" \
        "${COMPY_USER}@${COMPY_HOST}" \
        "$sudo_cmd"
}

compy_ssh_script() {
    # Usage: compy_ssh_script ARG...
    # Feeds the VPS setup script on stdin: `bash -s -- args`.
    _compy_paths
    _compy_require_host
    compy_ensure_ssh_key
    compy_ssh_base_opts
    compy_host_is_pinned || ynh_die --message="The VPS SSH host key is not pinned yet. Click Test connection, check the fingerprint, then click Pin host key."
    [[ -f "$COMPY_VPS_SCRIPT" ]] || ynh_die --message="The VPS setup script was not found at $COMPY_VPS_SCRIPT. Reinstall or upgrade the app so conf/vps_setup.sh is shipped."
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
    # apt on a fresh VPS can take several minutes.
    timeout 600 ssh "${COMPY_SSH_OPTS[@]}" \
        -o "StrictHostKeyChecking=yes" \
        "${COMPY_USER}@${COMPY_HOST}" \
        "$remote" \
        <"$COMPY_VPS_SCRIPT"
}

# ---------------------------- WG client conf ----------------------------

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

compy_write_client_conf() {
    # Args: server_pubkey endpoint_host endpoint_port server_ip peer_ip prefixlen subnet
    _compy_paths
    compy_ensure_wg_keys
    local server_pub="$1" endpoint_host="$2" endpoint_port="$3"
    local server_ip="$4" peer_ip="$5" prefixlen="$6" subnet="$7"
    local priv
    priv="$(tr -d '\n' <"$COMPY_WG_KEY")"
    _compy_is_wg_key "$server_pub" || ynh_die --message="The VPS returned an invalid server public key."
    umask 077
    cat >"$COMPY_CONF" <<EOF
[Interface]
# Generated by Compy Level 2. Do not add PostUp/PostDown or DNS=.
# AllowedIPs is the tunnel subnet only: this box's general internet
# traffic must keep using the home WAN, not the VPS.
Address = ${peer_ip}/${prefixlen}
PrivateKey = ${priv}

[Peer]
PublicKey = ${server_pub}
Endpoint = ${endpoint_host}:${endpoint_port}
AllowedIPs = ${subnet}
PersistentKeepalive = 25
EOF
    chown root:root "$COMPY_CONF"
    chmod 600 "$COMPY_CONF"
}

compy_start_tunnel() {
    _compy_paths
    [[ -f "$COMPY_CONF" ]] || ynh_die --message="Missing $COMPY_CONF"
    # So restore / integrate_services will start the tunnel at boot.
    ynh_app_setting_set --key="${COMPY_IF}_atboot" --value=1
    systemctl enable --quiet "wireguard_client@${COMPY_IF}.service" || true
    if systemctl is-active --quiet "wireguard_client@${COMPY_IF}.service"; then
        systemctl restart "wireguard_client@${COMPY_IF}.service" \
            || ynh_die --message="Failed to restart wireguard_client@${COMPY_IF}. Check journalctl -u wireguard_client@${COMPY_IF}."
    else
        systemctl start "wireguard_client@${COMPY_IF}.service" \
            || ynh_die --message="Failed to start wireguard_client@${COMPY_IF}. Check journalctl -u wireguard_client@${COMPY_IF}."
    fi
    # Register with YunoHost's service list (idempotent-ish).
    yunohost service add "wireguard_client@${COMPY_IF}" \
        --description="WireGuard VPN Client ${COMPY_IF} (Compy public access)" \
        --test_status="wg | grep \"interface: ${COMPY_IF}\" -q" 2>/dev/null || true
}

compy_verify_tunnel() {
    local server_ip="$1"
    local handshake
    # Wait up to ~20s for a handshake.
    local _try
    for ((_try=1; _try<=10; _try++)); do
        handshake="$(wg show "$COMPY_IF" latest-handshakes 2>/dev/null | awk '{print $2; exit}')"
        if [[ "$handshake" =~ ^[0-9]+$ ]] && ((handshake > 0)); then
            ynh_print_info "WireGuard handshake is up (latest-handshakes=$handshake)."
            if ping -c 3 -W 3 "$server_ip" >/dev/null 2>&1; then
                ynh_print_info "Ping to ${server_ip} (VPS tunnel address) succeeded."
                return 0
            else
                ynh_print_err "Handshake is up but ping to ${server_ip} failed. The tunnel may still be usable for forwarded ports; check wg show ${COMPY_IF} and the VPS log /var/log/compy-vps-setup.log."
                return 1
            fi
        fi
        sleep 2
    done
    ynh_die --message="No WireGuard handshake with the VPS after 20 seconds. The VPS script may have succeeded but this box cannot reach UDP ${COMPY_HOST:-}:$(_compy_setting compy_wg_port). Check the provider firewall (allow UDP $(_compy_setting compy_wg_port)) and journalctl -u wireguard_client@${COMPY_IF}."
}

# ---------------------------- result parsing ----------------------------

compy_parse_result() {
    # Reads a captured script output file, sets COMPY_RESULT_* globals.
    local out_file="$1"
    COMPY_RESULT_STATUS="$(awk -F= '/^COMPY_RESULT=/{print $2}' "$out_file" | tail -1)"
    COMPY_RESULT_ERROR="$(awk -F= '/^COMPY_ERROR=/{sub(/^[^=]+=/,""); print}' "$out_file" | tail -1)"
    COMPY_RESULT_PUBKEY="$(awk -F= '/^COMPY_SERVER_PUBKEY=/{print $2}' "$out_file" | tail -1)"
    COMPY_RESULT_WG_PORT="$(awk -F= '/^COMPY_ENDPOINT_PORT=/{print $2}' "$out_file" | tail -1)"
    COMPY_RESULT_SERVER_IP="$(awk -F= '/^COMPY_WG_SERVER_IP=/{print $2}' "$out_file" | tail -1)"
    COMPY_RESULT_PEER_IP="$(awk -F= '/^COMPY_WG_PEER_IP=/{print $2}' "$out_file" | tail -1)"
    COMPY_RESULT_SUBNET="$(awk -F= '/^COMPY_WG_SUBNET=/{print $2}' "$out_file" | tail -1)"
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
        ynh_die --message="The VPS script did not return a COMPY_RESULT line (ssh exit $rc). The VPS may have refused sudo, apt may have failed, or the SSH connection dropped. See the action log."
    fi
    compy_parse_result "$out"
    rm -f "$out" "${out}.err"
    if [[ "$COMPY_RESULT_STATUS" != "ok" || "$rc" -ne 0 ]]; then
        _compy_set compy_last_result "fail: ${COMPY_RESULT_ERROR:-unknown} (rc=$rc)"
        ynh_die --message="VPS setup failed: ${COMPY_RESULT_ERROR:-unknown error (exit $rc)}"
    fi
    _compy_set compy_last_result "ok"
    _compy_set compy_server_pubkey "$COMPY_RESULT_PUBKEY"
    _compy_set compy_server_ip "$COMPY_RESULT_SERVER_IP"
    _compy_set compy_peer_ip "${COMPY_RESULT_PEER_IP:-}"
}

# ---------------------------- getters ----------------------------

get__compy_ssh_pubkey() {
    compy_ensure_ssh_key
    # Raw value. Protect yaml-sensitive chars just in case, though an
    # OpenSSH pubkey line is usually plain.
    printf '"%s"\n' "$(tr -d '\n' <"$COMPY_SSH_PUB")"
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
    printf '%s\n' "$saved"
}

get__compy_ports_preview() {
    local ports
    ports="$(_compy_setting compy_ports || true)"
    [[ -n "$ports" ]] || ports="$(compy_default_ports)"
    cat <<EOF
style: info
ask:
  en: |
    Will be forwarded from the VPS public IP to this server's WireGuard address:
    \`${ports}\`

    The VPS SSH port and the WireGuard UDP port are never forwarded. The home SSH port is left out of the default list on purpose.
EOF
}

get__compy_status() {
    _compy_paths
    local style="info"
    local body="The tunnel has not been set up yet."
    local last handshake iface_state ping_s=""
    last="$(_compy_setting compy_last_result || true)"
    local server_ip
    server_ip="$(_compy_setting compy_server_ip || true)"

    if [[ -f "$COMPY_CONF" ]] && wg show "$COMPY_IF" >/dev/null 2>&1; then
        handshake="$(wg show "$COMPY_IF" latest-handshakes 2>/dev/null | awk '{print $2; exit}')"
        iface_state="$(cat /sys/class/net/${COMPY_IF}/operstate 2>/dev/null || echo unknown)"
        if [[ "$handshake" =~ ^[0-9]+$ ]] && ((handshake > 0)); then
            local ago=$(( $(date +%s) - handshake ))
            if ((ago < 180)); then
                style="success"
                body="Tunnel ${COMPY_IF} is up. Last handshake ${ago}s ago. Interface state: ${iface_state}."
            else
                style="warning"
                body="Tunnel ${COMPY_IF} exists but the last handshake was ${ago}s ago (WireGuard usually refreshes every ~25s with PersistentKeepalive). The VPS may be unreachable."
            fi
        else
            style="warning"
            body="Tunnel ${COMPY_IF} is configured but there is no handshake yet."
        fi
        if [[ -n "$server_ip" ]] && ping -c 1 -W 2 "$server_ip" >/dev/null 2>&1; then
            ping_s=" Ping to ${server_ip} succeeded."
        elif [[ -n "$server_ip" ]]; then
            ping_s=" Ping to ${server_ip} failed."
        fi
        body="${body}${ping_s}"
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
        local probe
        if [[ "$COMPY_USER" == "root" ]]; then
            probe="id -u && . /etc/os-release && echo COMPY_OS=\$ID \$VERSION_ID"
        else
            probe="sudo -n -- bash -c 'id -u && . /etc/os-release && echo COMPY_OS=\$ID \$VERSION_ID'"
        fi
        if ! output="$(compy_ssh "$probe")"; then
            ynh_die --message="Host key is pinned but login or passwordless sudo failed. On OVH Debian, the user is often 'debian' and must have sudo NOPASSWD (cloud-init usually sets this when you install the SSH key). Root login may be disabled."
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

    ynh_print_info "Connecting to ${COMPY_USER}@${COMPY_HOST}:${COMPY_SPORT} and running the VPS setup script. This can take a few minutes on a fresh Debian image."
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

    ynh_print_info "VPS is ready. Server public key: ${COMPY_RESULT_PUBKEY}. Writing the local client config and starting the tunnel."
    compy_write_client_conf "$COMPY_RESULT_PUBKEY" "$COMPY_HOST" "$ep_port" "$server_ip" "$peer_ip" "$prefixlen" "$subnet"
    compy_start_tunnel
    compy_verify_tunnel "$server_ip"
    ynh_print_info "Done. Point the domain DNS A record at ${COMPY_HOST} (no AAAA in this version), then click Test public ports. Let's Encrypt will keep running on this YunoHost box."
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
    ynh_print_info "Re-syncing ports on ${COMPY_HOST}: $ports"
    compy_run_vps_setup \
        --peer-pubkey "$peer_pub" \
        --ports "$ports" \
        --wg-port "$wg_port" \
        --ssh-port "$COMPY_SPORT" \
        --wg-subnet "$wg_subnet"
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

    # Official `yunohost diagnosis run ports` is the wrong vantage point:
    # diagnosis.yunohost.org probes the SOURCE IP of the request, which
    # from this home box is the home ISP address, not the VPS. We instead
    # POST the check from the VPS so the probe targets the VPS public IP.
    # (Inferred from the client API in src/diagnosis.py + 14-ports.py;
    # the server source was not re-read in this pass — see REPORT.md.)
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
    local result
    if ! result="$(compy_ssh "$probe_cmd")"; then
        ynh_die --message="Could not run the public port probe from the VPS. Install curl or python3 on the VPS, or check SSH/sudo. You can also run: yunohost diagnosis run web --force after pointing DNS at the VPS (the web diagnoser looks up the domain name, unlike the ports diagnoser)."
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

    ynh_print_info "Note: official 'yunohost diagnosis run ports' from this home box will likely still fail, because it probes the home ISP address, not the VPS. After DNS A points at the VPS, 'yunohost diagnosis run web --force' (and certificate issuance) is the better built-in check. You may need to ignore dnsrecords issues that compare the A record to the home WAN IP."
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
