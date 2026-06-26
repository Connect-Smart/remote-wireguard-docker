#!/usr/bin/env bash
set -o pipefail

INTERFACE="cswg0"
CONFIG_DIR="/etc/wireguard"
CONFIG_FILE="${CONFIG_DIR}/${INTERFACE}.conf"
CACHED_CONFIG_PATH="/data/wireguard_config.conf"

log_info()    { echo "[$(date '+%H:%M:%S')] INFO: $*"; }
log_warning() { echo "[$(date '+%H:%M:%S')] WARNING: $*"; }
log_error()   { echo "[$(date '+%H:%M:%S')] ERROR: $*"; }
log_fatal()   { echo "[$(date '+%H:%M:%S')] FATAL: $*"; exit 1; }

# -------------------------------------------------------
# DNS: voeg Supervisor/fallback DNS toe als nodig
# -------------------------------------------------------
ensure_dns() {
    local supervisor_dns="172.30.32.3"
    if ! grep -q "${supervisor_dns}" /etc/resolv.conf 2>/dev/null; then
        log_info "DNS: Supervisor DNS (${supervisor_dns}) toevoegen aan resolv.conf"
        local current
        current=$(cat /etc/resolv.conf 2>/dev/null || true)
        printf 'nameserver %s\nsearch local.hass.io\n%s\n' "${supervisor_dns}" "${current}" > /etc/resolv.conf
    fi
}

# -------------------------------------------------------
# WireGuard config ophalen van portal
# -------------------------------------------------------
fetch_remote_config() {
    local endpoint="${PORTAL_URL%/}/api/public/clients/${ENROLLMENT_TOKEN}/wireguard-config"
    local curl_opts=(
        "--silent" "--show-error" "--location"
        "--connect-timeout" "10" "--max-time" "30"
        "--header" "Accept: application/json"
        "--user-agent" "connect-smart-wireguard-docker/1.0"
        "--write-out" "\n%{http_code}"
    )
    [[ "${VERIFY_SSL,,}" == "false" ]] && curl_opts+=("--insecure")

    log_info "WireGuard-configuratie ophalen via: ${endpoint}"
    local raw http_code response
    if ! raw=$(curl "${curl_opts[@]}" "${endpoint}" 2>&1); then
        log_warning "Ophalen mislukt (netwerk/verbindingsfout)."
        return 1
    fi

    http_code=$(echo "${raw}" | tail -n1)
    response=$(echo "${raw}" | head -n-1)

    if [[ "${http_code}" != "200" && "${http_code}" != "201" ]]; then
        log_warning "Ophalen mislukt: HTTP ${http_code}."
        return 1
    fi

    WIREGUARD_CONFIG=$(echo "${response}" | jq -r '.wireguard // empty')
    if [[ -z "${WIREGUARD_CONFIG}" || "${WIREGUARD_CONFIG}" == "null" ]]; then
        log_warning "Geen geldige WireGuard-configuratie ontvangen."
        return 1
    fi
    return 0
}

# -------------------------------------------------------
# PersistentKeepalive toevoegen aan peers indien ontbreekt
# -------------------------------------------------------
ensure_persistent_keepalive() {
    local keepalive_value="${PERSISTENT_KEEPALIVE:-25}"
    local keepalive_line="PersistentKeepalive = ${keepalive_value}"
    local output="" in_peer="false" has_keepalive="false"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^[[:space:]]*\[Peer\][[:space:]]*$ ]]; then
            [[ "${in_peer}" == "true" && "${has_keepalive}" == "false" ]] && output+="${keepalive_line}"$'\n'
            in_peer="true"; has_keepalive="false"
        elif [[ "${line}" =~ ^[[:space:]]*\[.*\][[:space:]]*$ ]]; then
            [[ "${in_peer}" == "true" && "${has_keepalive}" == "false" ]] && output+="${keepalive_line}"$'\n'
            in_peer="false"; has_keepalive="false"
        elif [[ "${in_peer}" == "true" && "${line}" =~ ^[[:space:]]*PersistentKeepalive[[:space:]]*= ]]; then
            has_keepalive="true"
        fi
        output+="${line}"$'\n'
    done < <(printf '%s' "${WIREGUARD_CONFIG}")

    [[ "${in_peer}" == "true" && "${has_keepalive}" == "false" ]] && output+="${keepalive_line}"$'\n'
    WIREGUARD_CONFIG="${output:-${WIREGUARD_CONFIG}}"
}

# -------------------------------------------------------
# Portforwarding naar interne LAN-devices (DNAT)
# PORT_FORWARDS="luisterpoort:doel_ip:doel_poort[/tcp|udp],..."
# bv. PORT_FORWARDS="8080:192.168.1.50:80,2222:192.168.1.60:22/tcp"
# -------------------------------------------------------
ensure_chain() {
    local table="$1" chain="$2"
    iptables -t "${table}" -N "${chain}" 2>/dev/null || true
    iptables -t "${table}" -F "${chain}"
}

setup_port_forwards() {
    [[ -z "${PORT_FORWARDS}" ]] && return 0

    log_info "Portforwarding instellen: ${PORT_FORWARDS}"
    echo 1 > /proc/sys/net/ipv4/ip_forward

    ensure_chain nat CSWG_DNAT
    ensure_chain nat CSWG_MASQ
    ensure_chain filter CSWG_FWD

    iptables -t nat -C PREROUTING -j CSWG_DNAT 2>/dev/null || iptables -t nat -A PREROUTING -j CSWG_DNAT
    iptables -t nat -C POSTROUTING -j CSWG_MASQ 2>/dev/null || iptables -t nat -A POSTROUTING -j CSWG_MASQ
    iptables -C FORWARD -j CSWG_FWD 2>/dev/null || iptables -I FORWARD -j CSWG_FWD

    local entries entry proto listen_port dest dest_ip dest_port
    IFS=',' read -ra entries <<< "${PORT_FORWARDS}"
    for entry in "${entries[@]}"; do
        entry="${entry// /}"
        [[ -z "${entry}" ]] && continue

        proto="tcp"
        if [[ "${entry}" == */udp ]]; then
            proto="udp"; entry="${entry%/udp}"
        elif [[ "${entry}" == */tcp ]]; then
            entry="${entry%/tcp}"
        fi

        listen_port="${entry%%:*}"
        dest="${entry#*:}"
        dest_ip="${dest%%:*}"
        dest_port="${dest#*:}"

        if [[ -z "${listen_port}" || -z "${dest_ip}" || -z "${dest_port}" || "${dest_ip}" == "${dest}" ]]; then
            log_warning "Ongeldige PORT_FORWARDS-entry overgeslagen: ${entry}"
            continue
        fi

        log_info "Portforward: ${INTERFACE}:${listen_port}/${proto} -> ${dest_ip}:${dest_port}"
        iptables -t nat -A CSWG_DNAT -i "${INTERFACE}" -p "${proto}" --dport "${listen_port}" -j DNAT --to-destination "${dest_ip}:${dest_port}"
        iptables -t nat -A CSWG_MASQ -p "${proto}" -d "${dest_ip}" --dport "${dest_port}" -j MASQUERADE
        iptables -A CSWG_FWD -i "${INTERFACE}" -p "${proto}" -d "${dest_ip}" --dport "${dest_port}" -j ACCEPT
    done
}

teardown_port_forwards() {
    [[ -z "${PORT_FORWARDS}" ]] && return 0
    iptables -t nat -D PREROUTING -j CSWG_DNAT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j CSWG_MASQ 2>/dev/null || true
    iptables -D FORWARD -j CSWG_FWD 2>/dev/null || true
    iptables -t nat -F CSWG_DNAT 2>/dev/null || true
    iptables -t nat -F CSWG_MASQ 2>/dev/null || true
    iptables -F CSWG_FWD 2>/dev/null || true
    iptables -t nat -X CSWG_DNAT 2>/dev/null || true
    iptables -t nat -X CSWG_MASQ 2>/dev/null || true
    iptables -X CSWG_FWD 2>/dev/null || true
}

# -------------------------------------------------------
# Validatie
# -------------------------------------------------------
if [[ -z "${MANUAL_WIREGUARD_CONFIG}" && -z "${ENROLLMENT_TOKEN}" ]]; then
    log_fatal "ENROLLMENT_TOKEN is niet ingesteld."
fi

if [[ "${PORTAL_URL}" != http://* && "${PORTAL_URL}" != https://* ]]; then
    PORTAL_URL="https://${PORTAL_URL}"
fi

mkdir -p "${CONFIG_DIR}" /data

ensure_dns

# -------------------------------------------------------
# Config laden
# -------------------------------------------------------
WIREGUARD_CONFIG=""

if [[ -n "${MANUAL_WIREGUARD_CONFIG}" ]]; then
    log_info "Handmatige WireGuard-configuratie gebruiken."
    WIREGUARD_CONFIG="${MANUAL_WIREGUARD_CONFIG}"
elif fetch_remote_config; then
    log_info "WireGuard-configuratie succesvol opgehaald."
    printf '%s\n' "${WIREGUARD_CONFIG}" > "${CACHED_CONFIG_PATH}"
else
    if [[ -f "${CACHED_CONFIG_PATH}" ]]; then
        log_warning "Portal niet bereikbaar; gecachede configuratie wordt gebruikt."
        WIREGUARD_CONFIG=$(cat "${CACHED_CONFIG_PATH}")
    else
        log_fatal "Ophalen mislukt en er is geen gecachede configuratie beschikbaar."
    fi
fi

ensure_persistent_keepalive
printf '%s\n' "${WIREGUARD_CONFIG}" > "${CONFIG_FILE}"
chmod 600 "${CONFIG_FILE}"

# -------------------------------------------------------
# WireGuard starten
# -------------------------------------------------------
if ip link show "${INTERFACE}" &>/dev/null; then
    log_warning "Interface ${INTERFACE} bestond nog van een vorige run; wordt eerst opgeruimd."
    wg-quick down "${CONFIG_FILE}" 2>/dev/null || ip link delete "${INTERFACE}" 2>/dev/null || true
fi

log_info "WireGuard interface ${INTERFACE} starten..."
export WG_I_PREFER_BUGGY_USERSPACE_TO_POLISHED_KMOD=1
wg-quick up "${CONFIG_FILE}" || log_fatal "WireGuard starten mislukt."
log_info "WireGuard actief."

setup_port_forwards

# -------------------------------------------------------
# Watchdog starten
# -------------------------------------------------------
/watchdog.sh &
WATCHDOG_PID=$!

# -------------------------------------------------------
# Graceful shutdown
# -------------------------------------------------------
cleanup() {
    log_info "Afsluiten..."
    kill "${WATCHDOG_PID}" 2>/dev/null || true
    teardown_port_forwards
    wg-quick down "${CONFIG_FILE}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' SIGTERM SIGINT

log_info "Container actief. Wachten op signaal..."
wait "${WATCHDOG_PID}"
