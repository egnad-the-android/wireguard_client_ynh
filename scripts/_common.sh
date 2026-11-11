#!/bin/bash
# shellcheck disable=SC2154
# app and install_dir are set by the YunoHost helpers.

#=================================================
# COMMON VARIABLES AND CUSTOM HELPERS
#=================================================

# Directory of this file (scripts/), even when sourced from backup/restore.
_WIREGUARD_CLIENT_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WIREGUARD_CLIENT_PKG_DIR="$(cd "$_WIREGUARD_CLIENT_SCRIPTS_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$_WIREGUARD_CLIENT_SCRIPTS_DIR/_compy.sh"

compy_pkg_dir() {
    printf '%s' "${YNH_APP_BASEDIR:-$_WIREGUARD_CLIENT_PKG_DIR}"
}

# Initialize Compy panel settings once (install, or first upgrade from upstream).
# Empty strings are valid values for host/ports/last_result, so a sentinel is used.
compy_init_settings() {
    if [[ "$(ynh_app_setting_get --key=compy_initialized 2>/dev/null || true)" == "1" ]]; then
        return 0
    fi
    ynh_app_setting_set --key=compy_vps_host --value=""
    ynh_app_setting_set --key=compy_ssh_user --value="debian"
    ynh_app_setting_set --key=compy_ssh_port --value="22"
    ynh_app_setting_set --key=compy_wg_port --value="51820"
    ynh_app_setting_set --key=compy_wg_subnet --value="10.99.0.0/24"
    ynh_app_setting_set --key=compy_ports --value=""
    ynh_app_setting_set --key=compy_host_pinned --value="0"
    ynh_app_setting_set --key=compy_last_result --value=""
    ynh_app_setting_set --key=compy_bypass_nets --value=""
    ynh_app_setting_set --key=compy_full_tunnel --value="0"
    ynh_app_setting_set --key=compy_initialized --value="1"
}

# Fill keys added after the first Compy release, without overwriting values.
compy_ensure_settings() {
    compy_init_settings
    if [[ -z "$(ynh_app_setting_get --key=compy_bypass_nets 2>/dev/null || true)" ]]; then
        # Empty is also the "please auto-fill" sentinel used by the getter, so
        # only write the key when it is completely absent from settings.yml.
        if ! grep -q '^compy_bypass_nets:' "/etc/yunohost/apps/${app}/settings.yml" 2>/dev/null; then
            ynh_app_setting_set --key=compy_bypass_nets --value=""
        fi
    fi
    if [[ -z "$(ynh_app_setting_get --key=compy_full_tunnel 2>/dev/null || true)" ]]; then
        if ! grep -q '^compy_full_tunnel:' "/etc/yunohost/apps/${app}/settings.yml" 2>/dev/null; then
            ynh_app_setting_set --key=compy_full_tunnel --value="0"
        fi
    fi
}

# Copy shipped scripts into $install_dir so they are backed up and available
# even if YNH_APP_BASEDIR is not set.
compy_install_files() {
    local pkg
    pkg="$(compy_pkg_dir)"
    mkdir -p "$install_dir"
    if [[ -f "$pkg/conf/vps_setup.sh" ]]; then
        cp "$pkg/conf/vps_setup.sh" "$install_dir/vps_setup.sh"
        chmod 755 "$install_dir/vps_setup.sh"
        chown root:root "$install_dir/vps_setup.sh"
    fi
    if [[ -f "$pkg/scripts/ports_from_yunohost.sh" ]]; then
        cp "$pkg/scripts/ports_from_yunohost.sh" "$install_dir/ports_from_yunohost.sh"
        chmod 755 "$install_dir/ports_from_yunohost.sh"
        chown root:root "$install_dir/ports_from_yunohost.sh"
    fi
    local helper
    for helper in compy_route_up.sh compy_route_down.sh compy_watchdog.sh; do
        if [[ -f "$pkg/scripts/$helper" ]]; then
            cp "$pkg/scripts/$helper" "$install_dir/$helper"
            chmod 755 "$install_dir/$helper"
            chown root:root "$install_dir/$helper"
        fi
    done
    # Units are installed (timer off) so backup/restore paths always exist.
    compy_install_watchdog_units
}

# Rebuild the live config panel from the package template plus one part
# per Advanced interface. Always includes the [compy] page from the template.
compy_regen_config_panel() {
    local dest="/etc/yunohost/apps/${app}/config_panel.toml"
    local pkg
    pkg="$(compy_pkg_dir)"
    local template="$pkg/conf/config_panel.template.toml"
    [[ -f "$template" ]] || ynh_die --message="Missing $template; cannot rebuild the config panel."

    local TEMP_CONFIGPANEL
    TEMP_CONFIGPANEL="$(mktemp -d)"
    cat "$template" >"$dest"

    local interfaces_list i
    interfaces_list="$(ynh_app_setting_get --key=interfaces 2>/dev/null || true)"
    local IFS=','
    # shellcheck disable=SC2086
    for i in ${interfaces_list}; do
        i="${i//[$'\t\r\n ']/}"
        # The Compy tunnel is managed by the Public access page, not an upload widget.
        [[ -n "$i" && "$i" != "compy" ]] || continue
        ynh_config_add --template="config_panel.part.toml" --destination="$TEMP_CONFIGPANEL/config_panel.$i.toml"
        ynh_delete_file_checksum "$TEMP_CONFIGPANEL/config_panel.$i.toml" || true
    done
    for file in "$TEMP_CONFIGPANEL"/*; do
        [[ -f "$file" ]] || continue
        cat "$file" >>"$dest"
    done
    ynh_safe_rm "$TEMP_CONFIGPANEL"
}

compy_secure_conf_files() {
    local f
    shopt -s nullglob
    for f in "$install_dir"/*.conf; do
        chmod 600 "$f"
        chown root:root "$f"
    done
    shopt -u nullglob
}

integrate_services() {
    local file i atboot
    shopt -s nullglob
    for file in "$install_dir"/*.conf; do
        i="$(basename "$file" .conf)"
        systemctl enable --quiet "wireguard_client@$i.service"
        yunohost service add "wireguard_client@$i" --description="WireGuard VPN Client $i" --test_status="wg | grep \"interface: $i\" -q"
        atboot="$(ynh_app_setting_get --key="${i}_atboot" || true)"
        # The Compy tunnel should come back after restore even if atboot was never set.
        if [[ "$i" == "compy" ]]; then
            atboot="${atboot:-1}"
        fi
        if [[ "${atboot:-0}" -eq 1 ]]; then
            if [[ "$i" == "compy" ]] && grep -q '^AllowedIPs *= *0\.0\.0\.0/0' "$file"; then
                ynh_print_info "Starting the Compy full tunnel with verify-then-commit (rolls back if the VPS is not reachable)..."
                local server_ip public_ip
                server_ip="$(ynh_app_setting_get --key=compy_server_ip || true)"
                public_ip="$(ynh_app_setting_get --key=compy_public_ip || true)"
                if [[ -n "$server_ip" ]]; then
                    if ! compy_start_and_verify "$server_ip" "$public_ip"; then
                        ynh_print_err "Compy full tunnel was not started: verification failed and the change was rolled back."
                    fi
                else
                    ynh_print_err "Not auto-starting the Compy full tunnel (missing saved VPS tunnel address). Use the Public access panel."
                fi
            else
                ynh_print_info "$i interface was also enabled at boot, let's start it..."
                ynh_systemctl --service="wireguard_client@$i.service" --action=start || true
            fi
        fi
    done
    shopt -u nullglob
}
