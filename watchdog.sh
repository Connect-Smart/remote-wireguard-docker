#!/usr/bin/env bash
set -o pipefail

INTERFACE="cswg0"
CONFIG_DIR="/etc/wireguard"
CONFIG_FILE="${CONFIG_DIR}/${INTERFACE}.conf"
CACHED_CONFIG_PATH="/data/wireguard_config.conf"

TARGET="${MONITOR_TARGET:-10.8.0.1}"
INTERVAL="${MONITOR_INTERVAL:-30}"
PORTAL_URL="${PORTAL_URL:-https://remote.connect-smart.nl}"
ENROLLMENT_TOKEN="${ENROLLMENT_TOKEN:-}"
VERIFY_SSL="${VERIFY_SSL:-true}"

log_info()    { echo "[$(date '+%H:%M:%S')] INFO: $*"; }
log_warning() { echo "[$(date '+%H:%M:%S')] WARNING: $*"; }

FAILURE_COUNT=0

fetch_and_apply_config() {
    local endpoint="${PORTAL_URL%/}/api/public/clients/${ENROLLMENT_TOKEN}/wireguard-config"
    local curl_opts=(
        "--silent" "--show-error" "--location"
        "--connect-timeout" "10" "--max-time" "30"
        "--header" "Accept: application/json"
        "--user-agent" "connect-smart-wireguard-docker/1.0"
        "--write-out" "\n%{http_code}"
    )
    [[ "${VERIFY_SSL,,}" == "false" ]] && curl_opts+=("--insecure")

    local raw http_code response wg_config
    if ! raw=$(curl "${curl_opts[@]}" "${endpoint}" 2>&1); then
        log_warning "Watchdog: ophalen WireGuard-config mislukt."
        return 1
    fi

    http_code=$(echo "${raw}" | tail -n1)
    response=$(echo "${raw}" | head -n-1)

    if [[ "${http_code}" != "200" && "${http_code}" != "201" ]]; then
        log_warning "Watchdog: ophalen mislukt: HTTP ${http_code}."
        return 1
    fi

    wg_config=$(echo "${response}" | jq -r '.wireguard // empty')
    if [[ -z "${wg_config}" || "${wg_config}" == "null" ]]; then
        log_warning "Watchdog: geen geldige configuratie ontvangen."
        return 1
    fi

    local temp_file="${CONFIG_DIR}/${INTERFACE}.watchdog.conf"
    printf '%s\n' "${wg_config}" > "${temp_file}"

    if ! cmp -s "${temp_file}" "${CONFIG_FILE}"; then
        mv "${temp_file}" "${CONFIG_FILE}"
        cp "${CONFIG_FILE}" "${CACHED_CONFIG_PATH}"
        export WG_I_PREFER_BUGGY_USERSPACE_TO_POLISHED_KMOD=1
        if wg syncconf "${INTERFACE}" <(wg-quick strip "${CONFIG_FILE}"); then
            log_info "Watchdog: configuratie bijgewerkt en toegepast."
        else
            log_warning "Watchdog: wg syncconf mislukt."
        fi
    else
        rm -f "${temp_file}"
    fi
    return 0
}

# Wacht eerst zodat WireGuard tijd heeft de handshake op te bouwen
sleep "${INTERVAL}"

while true; do
    if ping -I "${INTERFACE}" -c 1 -W 2 "${TARGET}" >/dev/null 2>&1; then
        FAILURE_COUNT=0
        log_info "WireGuard ${INTERFACE}: verbonden"
    else
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        log_warning "WireGuard ${INTERFACE}: geen actieve verbinding (poging ${FAILURE_COUNT})"

        if [[ -n "${ENROLLMENT_TOKEN}" ]]; then
            log_info "Watchdog: WireGuard-configuratie opnieuw ophalen..."
            fetch_and_apply_config || log_warning "Watchdog: configuratie vernieuwen mislukt."
        fi

        if [[ "${FAILURE_COUNT}" -ge 5 ]]; then
            log_warning "Watchdog: ${FAILURE_COUNT} opeenvolgende fouten; container wordt gestopt voor herstart."
            exit 1
        fi
    fi

    sleep "${INTERVAL}"
done
