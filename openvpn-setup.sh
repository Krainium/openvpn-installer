#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  🔐🌐  openvpn-setup  —  OpenVPN Server Installer
#  PKI · TLS · UDP/TCP · Multi-DNS · Client Management · Multi-distro
# https://github.com/Krainium/openvpn-installer
# Copyright (c) 2026 Krainium. Released under the MIT License.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail   # NOTE: no -e so menu loops survive non-fatal command failures

# ─── Colours ──────────────────────────────────────────────────────────────────
R="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
RED="\033[31m"
GRN="\033[32m"
YLW="\033[33m"
BLU="\033[34m"
MAG="\033[35m"
CYN="\033[36m"
WHT="\033[97m"
PUR="\033[38;5;135m"
ORG="\033[38;5;208m"

# ─── Logging helpers ──────────────────────────────────────────────────────────
info()       { echo -e "${BLU}${BOLD}  ℹ  ${R}${WHT}$*${R}"; }
ok()         { echo -e "${GRN}${BOLD}  ✔  ${R}${GRN}$*${R}"; }
warn()       { echo -e "${YLW}${BOLD}  ⚠  ${R}${YLW}$*${R}"; }
err()        { echo -e "${RED}${BOLD}  ✖  ${R}${RED}$*${R}"; }
fatal()      { echo -e "${RED}${BOLD}  ✖  ${R}${RED}$*${R}"; exit 1; }
step()       { echo -e "\n${CYN}${BOLD}  ▶  $*${R}"; }
divider()    { echo -e "${DIM}  ──────────────────────────────────────────────────${R}"; }
installing() { echo -e "${MAG}${BOLD}  ⬇  ${R}${MAG}Installing $*...${R}"; }
prompt()     { echo -en "${CYN}${BOLD}  ➤  ${R}${WHT}$*${R}"; }

# ─── Root check ───────────────────────────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && { echo -e "\n  Run as root:  sudo bash $0\n"; exit 1; }

# ─── OS + package manager ─────────────────────────────────────────────────────
OS="unknown"; PM_UPDATE=""; PM_INSTALL=""

detect_os() {
    [[ -f /etc/os-release ]] && { source /etc/os-release; OS="${ID:-unknown}"; }
    if   command -v apt-get &>/dev/null; then
        PM_UPDATE="apt-get update -qq"
        PM_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y -qq"
    elif command -v dnf &>/dev/null; then
        PM_UPDATE="dnf check-update -q || true"
        PM_INSTALL="dnf install -y -q"
    elif command -v yum &>/dev/null; then
        PM_UPDATE="yum check-update -q || true"
        PM_INSTALL="yum install -y -q"
    elif command -v pacman &>/dev/null; then
        PM_UPDATE="pacman -Sy --noconfirm --quiet"
        PM_INSTALL="pacman -S --noconfirm --quiet"
    fi
}

# ─── State ────────────────────────────────────────────────────────────────────
STATE_DIR="/etc/openvpn-setup"
STATE_FILE="${STATE_DIR}/state.conf"
CLIENT_DIR="/root/openvpn-setup/clients"
EASYRSA_DIR="/etc/openvpn/easy-rsa"
SERVER_CONF="/etc/openvpn/server/server.conf"

# Runtime variables — populated by load_state or install wizard
SERVER_IP=""
SERVER_PORT="1194"
SERVER_PROTO="udp"
DNS1="8.8.8.8"
DNS2="8.8.4.4"
VPN_SUBNET="10.8.0.0"
VPN_MASK="255.255.255.0"

save_state() {
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
SERVER_IP="${SERVER_IP:-}"
SERVER_PORT="${SERVER_PORT:-1194}"
SERVER_PROTO="${SERVER_PROTO:-udp}"
DNS1="${DNS1:-8.8.8.8}"
DNS2="${DNS2:-8.8.4.4}"
VPN_SUBNET="${VPN_SUBNET:-10.8.0.0}"
VPN_MASK="${VPN_MASK:-255.255.255.0}"
EASYRSA_DIR="${EASYRSA_DIR:-/etc/openvpn/easy-rsa}"
EOF
    chmod 600 "$STATE_FILE"
}

load_state() {
    [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" || true
}

# ─── Helpers ──────────────────────────────────────────────────────────────────
is_installed() {
    [[ -f "$SERVER_CONF" ]] && command -v openvpn &>/dev/null
}

get_public_ip() {
    curl -4 -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
        || curl -4 -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -4 -fsSL --max-time 5 https://icanhazip.com 2>/dev/null \
        || echo ""
}

# Try openvpn-server@server first (Debian/Ubuntu systemd unit name),
# fall back to openvpn@server (RHEL / older setups)
openvpn_svc() {
    local action="$1"
    if systemctl "$action" openvpn-server@server 2>/dev/null; then
        return 0
    elif systemctl "$action" openvpn@server 2>/dev/null; then
        return 0
    fi
    return 1
}

# Run easy-rsa safely inside its own directory without changing the shell's cwd
easyrsa() {
    # All EASYRSA_* vars must be set before calling this
    ( cd "$EASYRSA_DIR" && ./easyrsa "$@" )
}

# ─── Banner ───────────────────────────────────────────────────────────────────
banner() {
    clear 2>/dev/null || true
    echo -e "${PUR}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║  🔐🌐  openvpn-setup   OpenVPN Server Installer        ║"
    echo "  ║  🔑 PKI  🛡️ TLS  📡 UDP/TCP  👥 Client Management      ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${R}"
    if is_installed; then
        load_state
        echo -e "  ${DIM}Server  : ${WHT}${BOLD}${SERVER_IP}:${SERVER_PORT}/${SERVER_PROTO}${R}"
        local n; n=$(find "$CLIENT_DIR" -name "*.ovpn" 2>/dev/null | wc -l)
        echo -e "  ${DIM}Clients : ${WHT}${n}${R}"
        echo ""
    fi
}

# ─── DNS selector ─────────────────────────────────────────────────────────────
select_dns() {
    echo -e "\n${CYN}${BOLD}  Select DNS for VPN clients:${R}"
    echo -e "  ${WHT}1${R}  Google         (8.8.8.8 / 8.8.4.4)"
    echo -e "  ${WHT}2${R}  Cloudflare     (1.1.1.1 / 1.0.0.1)"
    echo -e "  ${WHT}3${R}  OpenDNS        (208.67.222.222 / 208.67.220.220)"
    echo -e "  ${WHT}4${R}  Quad9          (9.9.9.9 / 149.112.112.112)"
    echo -e "  ${WHT}5${R}  AdGuard        (94.140.14.14 / 94.140.15.15)"
    echo -e "  ${WHT}6${R}  Current system (/etc/resolv.conf)"
    echo ""
    prompt "Choice [1]: "; read -r _d; _d="${_d:-1}"
    case "$_d" in
        1) DNS1="8.8.8.8";        DNS2="8.8.4.4" ;;
        2) DNS1="1.1.1.1";        DNS2="1.0.0.1" ;;
        3) DNS1="208.67.222.222"; DNS2="208.67.220.220" ;;
        4) DNS1="9.9.9.9";        DNS2="149.112.112.112" ;;
        5) DNS1="94.140.14.14";   DNS2="94.140.15.15" ;;
        6) DNS1=$(grep -m1 '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}')
           DNS2=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk 'NR==2{print $2}')
           DNS1="${DNS1:-8.8.8.8}"; DNS2="${DNS2:-8.8.4.4}" ;;
        *) DNS1="8.8.8.8"; DNS2="8.8.4.4" ;;
    esac
}

# ─── Install ──────────────────────────────────────────────────────────────────
install_openvpn() {
    detect_os
    step "Install OpenVPN Server"
    divider

    # ── Public IP
    info "Detecting public IP..."
    SERVER_IP=$(get_public_ip)
    if [[ -z "$SERVER_IP" ]]; then
        prompt "Public IP / hostname: "; read -r SERVER_IP
    else
        prompt "Public IP [${SERVER_IP}]: "; read -r _inp
        [[ -n "${_inp:-}" ]] && SERVER_IP="$_inp"
    fi
    [[ -z "$SERVER_IP" ]] && fatal "Server IP cannot be empty."
    ok "Server: ${SERVER_IP}"

    # ── Protocol
    echo -e "\n${CYN}${BOLD}  Protocol:${R}"
    echo -e "  ${WHT}1${R}  UDP  (faster — recommended)"
    echo -e "  ${WHT}2${R}  TCP  (for restricted networks / HTTP proxies)"
    prompt "Choice [1]: "; read -r _p; _p="${_p:-1}"
    [[ "$_p" == "2" ]] && SERVER_PROTO="tcp" || SERVER_PROTO="udp"
    ok "Protocol: ${SERVER_PROTO}"

    # ── Port
    local default_port; [[ "$SERVER_PROTO" == "tcp" ]] && default_port="443" || default_port="1194"
    prompt "Port [${default_port}]: "; read -r _port
    SERVER_PORT="${_port:-$default_port}"
    [[ ! "$SERVER_PORT" =~ ^[0-9]+$ ]] && SERVER_PORT="$default_port"
    ok "Port: ${SERVER_PORT}"

    # ── DNS
    select_dns
    ok "DNS: ${DNS1} / ${DNS2}"

    divider
    info "Starting installation — this will take 1–2 minutes..."

    # ── Packages
    installing "OpenVPN + easy-rsa"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openvpn easy-rsa curl openssl
    elif command -v dnf &>/dev/null; then
        dnf install -y epel-release 2>/dev/null || true
        dnf install -y openvpn easy-rsa curl openssl
    elif command -v yum &>/dev/null; then
        yum install -y epel-release 2>/dev/null || true
        yum install -y openvpn easy-rsa curl openssl
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm openvpn easy-rsa curl openssl
    else
        fatal "No supported package manager found. Install openvpn and easy-rsa manually."
    fi
    ok "OpenVPN and easy-rsa installed"

    # ── easy-rsa PKI
    step "Build PKI (Certificate Authority)"

    local easyrsa_bin=""
    for _p in /usr/share/easy-rsa/easyrsa /usr/bin/easyrsa /usr/local/bin/easyrsa; do
        [[ -x "$_p" ]] && { easyrsa_bin="$_p"; break; }
    done
    if [[ -z "${easyrsa_bin:-}" ]]; then
        easyrsa_bin=$(find /usr/share /usr/lib -name easyrsa -type f 2>/dev/null | head -1)
    fi
    [[ -z "${easyrsa_bin:-}" ]] && fatal "easy-rsa binary not found after installation."

    local easyrsa_src_dir; easyrsa_src_dir=$(dirname "$easyrsa_bin")
    rm -rf "$EASYRSA_DIR"
    cp -r "$easyrsa_src_dir" "$EASYRSA_DIR"
    chmod +x "${EASYRSA_DIR}/easyrsa"

    # All EASYRSA env vars in one place — exported here and also used by _add_client
    export EASYRSA_BATCH=1
    export EASYRSA_REQ_CN="openvpn-ca"
    export EASYRSA_ALGO="ec"
    export EASYRSA_DIGEST="sha512"
    export EASYRSA_CURVE="prime256v1"
    export EASYRSA_CA_EXPIRE=3650
    export EASYRSA_CERT_EXPIRE=3650

    info "Initializing PKI..."
    easyrsa init-pki
    ok "PKI initialized"

    info "Building CA (no passphrase)..."
    easyrsa build-ca nopass
    ok "CA built"

    info "Signing server certificate..."
    easyrsa build-server-full server nopass
    ok "Server certificate signed"

    easyrsa gen-crl
    ok "CRL generated"

    # TLS-crypt key
    info "Generating TLS-crypt key..."
    openvpn --genkey secret  "${EASYRSA_DIR}/pki/ta.key" 2>/dev/null \
        || openvpn --genkey --secret "${EASYRSA_DIR}/pki/ta.key" 2>/dev/null \
        || fatal "Failed to generate TLS key. Is openvpn installed correctly?"
    ok "TLS-crypt key generated"

    # ── Server config
    step "Write server config"
    mkdir -p /etc/openvpn/server /var/log/openvpn

    # nogroup exists on Debian/Ubuntu; RHEL uses nobody
    local srv_group
    srv_group=$(getent group nogroup &>/dev/null && echo "nogroup" || echo "nobody")

    cat > "$SERVER_CONF" <<OVPNCFG
port ${SERVER_PORT}
proto ${SERVER_PROTO}
dev tun

ca   ${EASYRSA_DIR}/pki/ca.crt
cert ${EASYRSA_DIR}/pki/issued/server.crt
key  ${EASYRSA_DIR}/pki/private/server.key
dh   none
crl-verify ${EASYRSA_DIR}/pki/crl.pem

server ${VPN_SUBNET} ${VPN_MASK}
topology subnet
ifconfig-pool-persist /var/log/openvpn/ipp.txt

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS ${DNS1}"
push "dhcp-option DNS ${DNS2}"

keepalive 10 120

tls-crypt ${EASYRSA_DIR}/pki/ta.key
cipher    AES-256-GCM
auth      SHA256
data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC

user  nobody
group ${srv_group}
persist-key
persist-tun

status  /var/log/openvpn/status.log
log     /var/log/openvpn/openvpn.log
verb 3
mute 20

tls-server
tls-version-min 1.2
OVPNCFG
    ok "Server config → ${SERVER_CONF}"

    # ── IP forwarding
    step "Enable IP forwarding"
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-openvpn.conf
    sysctl -p /etc/sysctl.d/99-openvpn.conf &>/dev/null || true
    ok "IP forwarding enabled"

    # ── Firewall / NAT
    step "Configure NAT"
    local NIC=""
    NIC=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
    [[ -z "${NIC:-}" ]] && NIC=$(ip link show | awk -F': ' '/^[0-9]+: [^lo]/{print $2; exit}')

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${SERVER_PORT}/${SERVER_PROTO}" &>/dev/null || true
        if ! grep -q "MASQUERADE" /etc/ufw/before.rules 2>/dev/null; then
            sed -i "1s;^;*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s ${VPN_SUBNET}/24 -o ${NIC} -j MASQUERADE\nCOMMIT\n\n;" \
                /etc/ufw/before.rules
        fi
        ufw reload &>/dev/null || true
        ok "UFW rules added"
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${SERVER_PORT}/${SERVER_PROTO}" &>/dev/null || true
        firewall-cmd --permanent --add-masquerade &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
        ok "firewalld rules added"
    else
        iptables -A INPUT   -p "${SERVER_PROTO}" --dport "${SERVER_PORT}" -j ACCEPT 2>/dev/null || true
        iptables -A FORWARD -s "${VPN_SUBNET}/24" -j ACCEPT 2>/dev/null || true
        iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
        iptables -t nat -A POSTROUTING -s "${VPN_SUBNET}/24" -o "${NIC}" -j MASQUERADE 2>/dev/null || true
        if command -v iptables-save &>/dev/null; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4
            cat > /etc/systemd/system/iptables-restore.service <<IPSVC
[Unit]
Description=Restore iptables rules
Before=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
IPSVC
            systemctl enable iptables-restore &>/dev/null || true
        fi
        ok "iptables NAT rules added"
    fi

    # ── Start OpenVPN
    step "Start OpenVPN"
    systemctl enable openvpn-server@server &>/dev/null \
        || systemctl enable openvpn@server &>/dev/null || true
    openvpn_svc restart || true
    sleep 2
    if systemctl is-active openvpn-server@server &>/dev/null \
        || systemctl is-active openvpn@server &>/dev/null; then
        ok "OpenVPN is running"
    else
        warn "OpenVPN may not have started — check: journalctl -u openvpn-server@server -n 30"
    fi

    save_state

    # ── Generate first client
    echo ""
    divider
    prompt "Name for the first client [client1]: "; read -r _cname
    _cname="${_cname:-client1}"; _cname="${_cname// /_}"
    _add_client "$_cname"
    divider
    ok "OpenVPN server is ready!"
    echo -e "  ${DIM}Client file → ${ORG}${CLIENT_DIR}/${_cname}.ovpn${R}"
    echo ""
}

# ─── Generate .ovpn for one client ───────────────────────────────────────────
# This function is safe to call from the management menu at any time.
# It re-exports all EASYRSA vars and never changes the shell's working directory.
_add_client() {
    local name="$1"

    # Always load saved state so SERVER_IP / SERVER_PORT / SERVER_PROTO are current
    load_state

    mkdir -p "$CLIENT_DIR"

    # Re-export every EASYRSA var so this works whether called from install or menu
    export EASYRSA_BATCH=1
    export EASYRSA_REQ_CN="openvpn-ca"
    export EASYRSA_ALGO="ec"
    export EASYRSA_DIGEST="sha512"
    export EASYRSA_CURVE="prime256v1"
    export EASYRSA_CA_EXPIRE=3650
    export EASYRSA_CERT_EXPIRE=3650

    if [[ -f "${EASYRSA_DIR}/pki/issued/${name}.crt" ]]; then
        warn "Certificate for '${name}' already exists — reusing it"
    else
        info "Generating certificate for '${name}'..."
        if ! easyrsa build-client-full "$name" nopass; then
            err "Failed to generate certificate for '${name}'. Check the PKI at ${EASYRSA_DIR}/"
            return 1
        fi
        ok "Certificate generated for '${name}'"
    fi

    # Verify the expected files exist before embedding them
    local ca_file="${EASYRSA_DIR}/pki/ca.crt"
    local crt_file="${EASYRSA_DIR}/pki/issued/${name}.crt"
    local key_file="${EASYRSA_DIR}/pki/private/${name}.key"
    local ta_file="${EASYRSA_DIR}/pki/ta.key"

    for f in "$ca_file" "$crt_file" "$key_file" "$ta_file"; do
        [[ -f "$f" ]] || { err "Missing file: $f"; return 1; }
    done

    local ca cert key ta
    ca=$(cat "$ca_file")
    cert=$(openssl x509 -in "$crt_file" 2>/dev/null)
    key=$(cat "$key_file")
    ta=$(cat "$ta_file")

    cat > "${CLIENT_DIR}/${name}.ovpn" <<OVPN
client
dev tun
proto ${SERVER_PROTO}
remote ${SERVER_IP} ${SERVER_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun

remote-cert-tls server

cipher AES-256-GCM
auth SHA256
data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC

key-direction 1
verb 3

<ca>
${ca}
</ca>
<cert>
${cert}
</cert>
<key>
${key}
</key>
<tls-crypt>
${ta}
</tls-crypt>
OVPN

    chmod 600 "${CLIENT_DIR}/${name}.ovpn"
    ok "Client config → ${CLIENT_DIR}/${name}.ovpn"
    echo -e "  ${DIM}Copy this file to the client device and import it into any OpenVPN app.${R}"
}

# ─── Add client (interactive) ─────────────────────────────────────────────────
add_client() {
    step "Add OpenVPN Client"
    prompt "Client name: "; read -r _name
    _name="${_name// /_}"
    if [[ -z "$_name" ]]; then
        warn "Name cannot be empty."; return
    fi
    if [[ -f "${CLIENT_DIR}/${_name}.ovpn" ]]; then
        warn "Client '${_name}' already has a config file at ${CLIENT_DIR}/${_name}.ovpn"
        return
    fi
    _add_client "$_name"
}

# ─── Remove / revoke client ───────────────────────────────────────────────────
remove_client() {
    step "Remove OpenVPN Client"

    local clients=()
    while IFS= read -r f; do
        clients+=("$(basename "$f" .ovpn)")
    done < <(find "$CLIENT_DIR" -name "*.ovpn" 2>/dev/null | sort)

    if [[ ${#clients[@]} -eq 0 ]]; then
        warn "No clients found in ${CLIENT_DIR}"; return
    fi

    echo ""
    local i=1
    for c in "${clients[@]}"; do
        echo -e "  ${WHT}${i}${R}  ${c}"; ((i++))
    done
    echo ""
    prompt "Select client to remove (number): "; read -r _n
    if [[ ! "$_n" =~ ^[0-9]+$ || "$_n" -lt 1 || "$_n" -gt "${#clients[@]}" ]]; then
        warn "Invalid selection."; return
    fi
    local target="${clients[$((_n - 1))]}"
    echo -en "${YLW}${BOLD}  Revoke certificate for '${target}'? [y/N]: ${R}"
    read -r _c
    [[ "${_c,,}" != "y" ]] && { info "Cancelled."; return; }

    export EASYRSA_BATCH=1
    if ! ( cd "$EASYRSA_DIR" && ./easyrsa revoke "$target" ); then
        warn "easyrsa revoke returned an error — continuing anyway"
    fi
    ( cd "$EASYRSA_DIR" && ./easyrsa gen-crl ) || true
    rm -f "${CLIENT_DIR}/${target}.ovpn"
    ok "'${target}' certificate revoked and config removed"
    # Reload so the new CRL takes effect without dropping active connections
    openvpn_svc reload || openvpn_svc restart || true
}

# ─── List clients ─────────────────────────────────────────────────────────────
list_clients() {
    step "OpenVPN Clients"
    local files=()
    while IFS= read -r f; do files+=("$f"); done < <(find "$CLIENT_DIR" -name "*.ovpn" 2>/dev/null | sort)

    if [[ ${#files[@]} -eq 0 ]]; then
        warn "No client .ovpn files found in ${CLIENT_DIR}"; return
    fi
    echo ""
    for f in "${files[@]}"; do
        local name; name=$(basename "$f" .ovpn)
        local sz;   sz=$(du -sh "$f" 2>/dev/null | cut -f1)
        echo -e "  ${GRN}●${R}  ${WHT}${name}${R}  ${DIM}(${sz})${R}"
        echo -e "       ${DIM}${f}${R}"
    done
    echo ""
    ok "${#files[@]} client config(s) found in ${CLIENT_DIR}"
}

# ─── Status ───────────────────────────────────────────────────────────────────
show_status() {
    load_state
    step "OpenVPN Status"
    divider
    echo -e "  ${DIM}Server    : ${WHT}${SERVER_IP}:${SERVER_PORT}/${SERVER_PROTO}${R}"
    echo -e "  ${DIM}Subnet    : ${WHT}${VPN_SUBNET}/24${R}"
    echo -e "  ${DIM}DNS       : ${WHT}${DNS1} / ${DNS2}${R}"
    echo -e "  ${DIM}Clients   : ${WHT}$(find "$CLIENT_DIR" -name "*.ovpn" 2>/dev/null | wc -l) config file(s) in ${CLIENT_DIR}${R}"
    echo ""

    local running=0
    if   systemctl is-active openvpn-server@server &>/dev/null; then
        systemctl status openvpn-server@server --no-pager -l 2>/dev/null | head -18
        running=1
    elif systemctl is-active openvpn@server &>/dev/null; then
        systemctl status openvpn@server --no-pager -l 2>/dev/null | head -18
        running=1
    fi
    [[ "$running" -eq 0 ]] && warn "OpenVPN is not running"

    echo ""
    if [[ -f /var/log/openvpn/status.log ]]; then
        echo -e "${CYN}${BOLD}  Connected clients:${R}"
        local connected
        connected=$(grep "^CLIENT_LIST," /var/log/openvpn/status.log 2>/dev/null \
            | grep -v "Common Name" \
            | awk -F',' '{printf "  %-20s  %-18s  rx:%-10s  tx:%s\n", $2,$4,$6,$7}')
        if [[ -n "${connected:-}" ]]; then
            echo "$connected"
        else
            echo -e "  ${DIM}No clients currently connected${R}"
        fi
    fi
}

# ─── Restart ──────────────────────────────────────────────────────────────────
restart_openvpn() {
    step "Restart OpenVPN"
    if openvpn_svc restart; then
        ok "OpenVPN restarted successfully"
    else
        warn "Could not restart OpenVPN — check logs:"
        echo -e "  ${DIM}journalctl -u openvpn-server@server -n 30 --no-pager${R}"
    fi
}

# ─── Uninstall ────────────────────────────────────────────────────────────────
uninstall_openvpn() {
    step "Uninstall OpenVPN"
    echo ""
    echo -e "${RED}${BOLD}  ⚠  This will remove everything:${R}"
    echo -e "  ${DIM}  • OpenVPN server and all its config${R}"
    echo -e "  ${DIM}  • All certificates and the CA${R}"
    echo -e "  ${DIM}  • All client .ovpn files in ${CLIENT_DIR}${R}"
    echo ""
    echo -en "${YLW}${BOLD}  Type YES to confirm: ${R}"
    read -r _c
    [[ "$_c" != "YES" ]] && { info "Cancelled."; return; }

    info "Stopping OpenVPN..."
    openvpn_svc stop || true
    systemctl disable openvpn-server@server &>/dev/null \
        || systemctl disable openvpn@server &>/dev/null || true

    info "Removing packages..."
    if   command -v apt-get &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get remove -y openvpn easy-rsa &>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf remove -y openvpn easy-rsa &>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum remove -y openvpn easy-rsa &>/dev/null || true
    elif command -v pacman &>/dev/null; then
        pacman -R --noconfirm openvpn easy-rsa &>/dev/null || true
    fi

    info "Removing files..."
    rm -rf "$EASYRSA_DIR" "$STATE_DIR" "$CLIENT_DIR" \
           /var/log/openvpn /etc/openvpn/server \
           /etc/sysctl.d/99-openvpn.conf \
           /etc/systemd/system/iptables-restore.service
    [[ -f /etc/iptables/rules.v4 ]] && rm -f /etc/iptables/rules.v4
    systemctl daemon-reload &>/dev/null || true

    ok "OpenVPN has been completely removed"
    echo ""
    exit 0
}

# ─── Menu ─────────────────────────────────────────────────────────────────────
print_menu() {
    echo -e "${CYN}${BOLD}  ┌─ Client Management ───────────────────────────────────┐${R}"
    echo -e "  ${WHT}  1${R}  👤  Add Client"
    echo -e "  ${WHT}  2${R}  🗑   Remove Client"
    echo -e "  ${WHT}  3${R}  📋  List Clients"
    echo -e "${CYN}${BOLD}  ├─ Server ──────────────────────────────────────────────┤${R}"
    echo -e "  ${WHT}  4${R}  📊  Status"
    echo -e "  ${WHT}  5${R}  🔄  Restart OpenVPN"
    echo -e "  ${WHT}  6${R}  🗑   Uninstall OpenVPN"
    echo -e "${CYN}${BOLD}  └────────────────────────────────────────────────────────┘${R}"
    echo -e "  ${WHT}  0${R}  ❌  Exit"
    echo ""
    echo -en "${CYN}${BOLD}  Choice: ${R}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    if ! is_installed; then
        banner
        echo -e "  ${YLW}OpenVPN is not installed yet.${R}  Starting fresh installation...\n"
        sleep 1
        install_openvpn
        echo ""
        prompt "Press Enter to open the management menu..."; read -r
    fi

    while true; do
        banner
        print_menu
        read -r choice
        echo ""
        case "$choice" in
            1) add_client ;;
            2) remove_client ;;
            3) list_clients ;;
            4) show_status ;;
            5) restart_openvpn ;;
            6) uninstall_openvpn ;;
            0|q|Q) echo -e "  ${DIM}Goodbye.${R}"; exit 0 ;;
            *) warn "Invalid choice — enter a number from 0 to 6." ;;
        esac
        echo ""
        echo -en "${DIM}  Press Enter to continue...${R}"; read -r
    done
}

main "$@"
