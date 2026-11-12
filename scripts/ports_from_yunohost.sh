#!/usr/bin/env bash
# The Gate — extract the ports that should be public from a YunoHost box.
# Intended to run on the home Compy (YunoHost server), as root.
#
# YunoHost 12+ stores the firewall as /etc/yunohost/firewall.yml with this
# shape (verified against YunoHost/yunohost dev src/firewall.py and
# conf/yunohost/firewall.yml, 2026-11):
#
#   router_forwarding_upnp: false
#   tcp:
#     80:
#       open: true
#       upnp: true
#       comment: "HTTP server (nginx)"
#     8000-8010:
#       open: true
#       upnp: false
#       comment: "a range, dash-separated (legacy colon is rewritten to dash)"
#   udp:
#     53:
#       open: true
#       upnp: false
#       comment: "DNS server (dnsmasq)"
#
# There is no ipv4/ipv6 split in the current file. The older
#   ipv4: { TCP: [80, 443], UDP: [53] }
# layout is obsolete and is only accepted here as a fallback parser.
#
# CLI (verified from share/actionsmap.yml + firewall_list()):
#   yunohost firewall list --raw     complete YAML/dict of the file
#   yunohost firewall list           {"tcp": [open TCP ports]}  (default protocol)
#   yunohost firewall list -p udp    {"udp": [open UDP ports]}
# There is NO dedicated --json flag. Moulinette's global --output-as json
# usually works (`yunohost --output-as json firewall list --raw`) but that
# was not executed here (yunohost is not installed on this box).
#
# IMPORTANT: "open" on the home firewall only means YunoHost's nftables on
# this box accepts the port. It does NOT mean the port is forwarded on the
# ISP router or reachable from the internet. That is the gap The Gate
# fills.
#
# Default exclusions (safe list):
#   TCP: the home SSH port (sshd_config or 22), and 53
#   UDP: 53, 1900 (UPnP), 5353 (mDNS), 55354 (YunoHost UPnP helper)
# The home SSH port is excluded so the VPS does not publish the home SSH
# daemon. (The VPS script will also refuse to DNAT its own SSH/WG ports.)
#
# Output (stdout, one line), canonical form used by vps_setup.sh:
#   tcp:25,80,443,587,993,5222,5269;udp:
#
# Usage:
#   ports_from_yunohost.sh              # print the safe list
#   ports_from_yunohost.sh --all        # every open port, no exclusions
#   ports_from_yunohost.sh --json       # JSON object with tcp/udp/canonical
#   source ports_from_yunohost.sh
#   compy_ports_from_yunohost           # sets COMPY_PORTS, COMPY_PORTS_TCP, ...
#
# Prefers python3 (always present on YunoHost). Does not require jq.

# nounset only when executed as a script, not when sourced from scripts/config.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -u
fi

COMPY_PORTS_EXCLUDE_TCP_DEFAULT="53"
COMPY_PORTS_EXCLUDE_UDP_DEFAULT="53,1900,5353,55354"

_compy_home_ssh_port() {
    local port=""
    if [[ -r /etc/ssh/sshd_config ]]; then
        port="$(awk 'tolower($1)=="port" {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
    fi
    if [[ "$port" =~ ^[0-9]+$ ]]; then
        printf '%s' "$port"
    else
        printf '22'
    fi
}

# Python parser: handles the current firewall.yml and the legacy ipv4/ipv6 layout.
# Prints two lines: "tcp:a,b,c" and "udp:..." with no exclusions applied.
_compy_read_firewall_python() {
    python3 - <<'PY'
import json, os, sys

path = "/etc/yunohost/firewall.yml"

def as_port_token(k):
    return str(k).replace(":", "-").strip()

def collect_current(doc):
    tcp, udp = [], []
    for proto, dest in (("tcp", tcp), ("udp", udp)):
        block = doc.get(proto) or {}
        if not isinstance(block, dict):
            continue
        for port, status in block.items():
            if not isinstance(status, dict):
                continue
            if status.get("open"):
                dest.append(as_port_token(port))
    return tcp, udp

def collect_legacy(doc):
    tcp, udp = [], []
    seen_t, seen_u = set(), set()
    for fam in ("ipv4", "ipv6"):
        block = doc.get(fam) or {}
        if not isinstance(block, dict):
            continue
        for key, dest, seen in (
            ("TCP", tcp, seen_t),
            ("UDP", udp, seen_u),
            ("tcp", tcp, seen_t),
            ("udp", udp, seen_u),
        ):
            for p in block.get(key) or []:
                tok = as_port_token(p)
                if tok not in seen:
                    seen.add(tok)
                    dest.append(tok)
    return tcp, udp

doc = None
if os.path.isfile(path):
    try:
        import yaml  # PyYAML is a YunoHost dependency
        with open(path, "r", encoding="utf-8") as f:
            doc = yaml.safe_load(f) or {}
    except Exception as e:
        print("failed to parse %s: %s" % (path, e), file=sys.stderr)
        doc = None

if not doc:
    import subprocess
    for argv in (
        ["yunohost", "--output-as", "json", "firewall", "list", "--raw"],
        ["yunohost", "firewall", "list", "--raw", "--output-as", "json"],
    ):
        try:
            out = subprocess.check_output(argv, stderr=subprocess.DEVNULL, text=True)
            doc = json.loads(out)
            if doc:
                break
        except Exception:
            doc = None

if not doc:
    sys.stderr.write("could not read YunoHost firewall (no /etc/yunohost/firewall.yml and CLI failed)\n")
    sys.exit(2)

if "tcp" in doc or "udp" in doc:
    tcp, udp = collect_current(doc)
elif "ipv4" in doc or "ipv6" in doc:
    tcp, udp = collect_legacy(doc)
else:
    sys.stderr.write("unrecognised firewall.yml structure\n")
    sys.exit(3)

def sort_tokens(tokens):
    def key(t):
        a = t.split("-", 1)[0]
        try:
            return int(a)
        except ValueError:
            return 0
    return sorted(tokens, key=key)

tcp = sort_tokens(tcp)
udp = sort_tokens(udp)
print("tcp:" + ",".join(tcp))
print("udp:" + ",".join(udp))
PY
}

_compy_token_covers() {
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

_compy_filter_list() {
    local excludes="$1"
    shift
    local tok ex keep
    local -a out=()
    for tok in "$@"; do
        keep=1
        local IFS=','
        # shellcheck disable=SC2086
        for ex in $excludes; do
            [[ -n "$ex" ]] || continue
            if _compy_token_covers "$tok" "$ex"; then
                keep=0
                break
            fi
        done
        [[ $keep -eq 1 ]] && out+=("$tok")
    done
    local IFS=','
    printf '%s' "${out[*]-}"
}

compy_ports_from_yunohost() {
    # Flags via env:
    #   COMPY_PORTS_ALL=1         do not exclude
    #   COMPY_PORTS_EXCLUDE_TCP   override
    #   COMPY_PORTS_EXCLUDE_UDP   override
    local raw tcp_line udp_line
    raw="$(_compy_read_firewall_python)" || return $?
    tcp_line="$(printf '%s\n' "$raw" | awk -F: '/^tcp:/{print $2; exit}')"
    udp_line="$(printf '%s\n' "$raw" | awk -F: '/^udp:/{print $2; exit}')"

    local -a tcp_arr=() udp_arr=()
    local IFS=','
    # shellcheck disable=SC2206
    [[ -n "$tcp_line" ]] && tcp_arr=($tcp_line)
    # shellcheck disable=SC2206
    [[ -n "$udp_line" ]] && udp_arr=($udp_line)

    if [[ "${COMPY_PORTS_ALL:-0}" != "1" ]]; then
        local ex_tcp ex_udp ssh_port
        ssh_port="$(_compy_home_ssh_port)"
        ex_tcp="${COMPY_PORTS_EXCLUDE_TCP:-$COMPY_PORTS_EXCLUDE_TCP_DEFAULT}"
        ex_udp="${COMPY_PORTS_EXCLUDE_UDP:-$COMPY_PORTS_EXCLUDE_UDP_DEFAULT}"
        ex_tcp="${ex_tcp},${ssh_port}"
        tcp_line="$(_compy_filter_list "$ex_tcp" ${tcp_arr[@]+"${tcp_arr[@]}"})"
        udp_line="$(_compy_filter_list "$ex_udp" ${udp_arr[@]+"${udp_arr[@]}"})"
    fi

    COMPY_PORTS_TCP="${tcp_line:-}"
    COMPY_PORTS_UDP="${udp_line:-}"
    COMPY_PORTS="tcp:${COMPY_PORTS_TCP};udp:${COMPY_PORTS_UDP}"
    # If both lists ended up empty, fall back to a minimal public web/mail set.
    if [[ -z "$COMPY_PORTS_TCP" && -z "$COMPY_PORTS_UDP" ]]; then
        COMPY_PORTS_TCP="25,80,443,587,993"
        COMPY_PORTS_UDP=""
        COMPY_PORTS="tcp:${COMPY_PORTS_TCP};udp:"
        COMPY_PORTS_FALLBACK=1
    else
        COMPY_PORTS_FALLBACK=0
    fi
    printf '%s\n' "$COMPY_PORTS"
}

# Only run the CLI if this file is executed, not sourced.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    ALL=0
    WANT_JSON=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) ALL=1; shift ;;
            --json) WANT_JSON=1; shift ;;
            -h|--help)
                sed -n '2,80p' "$0" | sed 's/^# \?//'
                exit 0
                ;;
            *) echo "unknown argument: $1" >&2; exit 1 ;;
        esac
    done
    COMPY_PORTS_ALL="$ALL"
    if ! canon="$(compy_ports_from_yunohost)"; then
        echo "failed to extract ports" >&2
        exit 1
    fi
    if [[ "$WANT_JSON" -eq 1 ]]; then
        python3 -c '
import json, sys
canon = sys.argv[1]
fallback = sys.argv[2] == "1"
tcp = udp = ""
for part in canon.split(";"):
    if part.startswith("tcp:"):
        tcp = part[4:]
    elif part.startswith("udp:"):
        udp = part[4:]
print(json.dumps({
    "tcp": [p for p in tcp.split(",") if p],
    "udp": [p for p in udp.split(",") if p],
    "canonical": canon,
    "fallback": fallback,
}))
' "$canon" "${COMPY_PORTS_FALLBACK:-0}"
    else
        printf '%s\n' "$canon"
    fi
fi
