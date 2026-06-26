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
log_info "WireGuard interface ${INTERFACE} starten..."
export WG_I_PREFER_BUGGY_USERSPACE_TO_POLISHED_KMOD=1
wg-quick up "${CONFIG_FILE}" || log_fatal "WireGuard starten mislukt."
log_info "WireGuard actief."

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
    wg-quick down "${CONFIG_FILE}" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

log_info "Container actief. Wachten op signaal..."
wait "${WATCHDOG_PID}"
