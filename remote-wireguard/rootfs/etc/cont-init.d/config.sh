#!/usr/bin/with-contenv bashio
# ==============================================================================
# Home Assistant Third Party Add-on: WireGuard Client
# Haalt een WireGuard-configuratie op uit Remote Portal en schrijft deze naar een add-on specifieke interface.
# ==============================================================================

set -o pipefail

INTERFACE="cswg0"
SETTINGS_PATH="/data/settings.json"
CACHED_CONFIG_PATH="/data/wireguard_config.conf"
CONFIG_DIR="/etc/wireguard"
CONFIG_FILE="${CONFIG_DIR}/${INTERFACE}.conf"
TEMP_FILE="${CONFIG_DIR}/${INTERFACE}.new.conf"

PORTAL_URL="https://remote.connect-smart.nl"
ENROLLMENT_TOKEN=""
VERIFY_SSL="true"
WIREGUARD_CONFIG=""
CLIENT_NAME=""
CLIENT_EXTERNAL_URL=""
LAN_ROUTES=""
PERSISTENT_KEEPALIVE="25"
MANUAL_WIREGUARD_CONFIG=""

ensure_dns() {
    local supervisor_dns="172.30.32.3"

    # Voeg Supervisor DNS toe als die nog niet in resolv.conf staat
    if ! grep -q "${supervisor_dns}" /etc/resolv.conf 2>/dev/null; then
        bashio::log.info "DNS: HA Supervisor DNS (${supervisor_dns}) toevoegen aan resolv.conf"
        local current_resolv
        current_resolv=$(cat /etc/resolv.conf 2>/dev/null || true)
        printf 'nameserver %s\nsearch local.hass.io\n%s\n' "${supervisor_dns}" "${current_resolv}" > /etc/resolv.conf
    fi
}

normalize_boolean() {
    local input="${1:-true}"
    input=$(echo "${input}" | tr '[:upper:]' '[:lower:]')
    case "${input}" in
        1 | true | yes | on) echo "true" ;;
        *) echo "false" ;;
    esac
}

load_settings_file() {
    if [[ ! -f "${SETTINGS_PATH}" ]]; then
        return
    fi
    bashio::log.info "Instellingen laden uit ${SETTINGS_PATH}"
    if ! settings_json=$(cat "${SETTINGS_PATH}"); then
        bashio::log.warning "Kan ${SETTINGS_PATH} niet lezen."
        return
    fi
    local value
    value=$(echo "${settings_json}" | jq -r '.portal_url // empty')
    if [[ -n "${value}" ]]; then
        PORTAL_URL="${value}"
    fi
    value=$(echo "${settings_json}" | jq -r '.enrollment_token // empty')
    if [[ -n "${value}" ]]; then
        ENROLLMENT_TOKEN="${value}"
    fi
    value=$(echo "${settings_json}" | jq -r '.verify_ssl // empty')
    if [[ -n "${value}" && "${value}" != "null" ]]; then
        VERIFY_SSL="${value}"
    fi
}

load_addon_options() {
    if bashio::config.has_value "advanced.portal_url"; then
        PORTAL_URL=$(bashio::config "advanced.portal_url")
    elif bashio::config.has_value "portal_url"; then
        PORTAL_URL=$(bashio::config "portal_url")
    fi
    if bashio::config.has_value "enrollment_token"; then
        ENROLLMENT_TOKEN=$(bashio::config "enrollment_token")
    fi
    if bashio::config.has_value "advanced.verify_ssl"; then
        VERIFY_SSL=$(bashio::config "advanced.verify_ssl")
    elif bashio::config.has_value "verify_ssl"; then
        VERIFY_SSL=$(bashio::config "verify_ssl")
    fi
    if bashio::config.has_value "advanced.manual_wireguard_config"; then
        MANUAL_WIREGUARD_CONFIG=$(bashio::config "advanced.manual_wireguard_config")
    fi
}

persist_settings() {
    local verify_json="true"
    if [[ "${VERIFY_SSL}" != "true" ]]; then
        verify_json="false"
    fi
    mkdir -p "$(dirname "${SETTINGS_PATH}")"
    if ! jq -n \
        --arg portal "${PORTAL_URL}" \
        --arg token "${ENROLLMENT_TOKEN}" \
        --argjson verify "${verify_json}" \
        '{portal_url: $portal, enrollment_token: $token, verify_ssl: $verify}' \
        > "${SETTINGS_PATH}.tmp"; then
        bashio::log.warning "Kon tijdelijke instellingen niet schrijven."
        rm -f "${SETTINGS_PATH}.tmp"
        return
    fi
    mv "${SETTINGS_PATH}.tmp" "${SETTINGS_PATH}"
}

ensure_inputs() {
    PORTAL_URL=$(echo "${PORTAL_URL}" | xargs)
    ENROLLMENT_TOKEN=$(echo "${ENROLLMENT_TOKEN}" | xargs)
    VERIFY_SSL=$(normalize_boolean "${VERIFY_SSL}")

    # Bij handmatige config zijn portal_url en enrollment_token optioneel
    if [[ -n "${MANUAL_WIREGUARD_CONFIG}" ]]; then
        return
    fi

    if [[ -z "${PORTAL_URL}" ]]; then
        bashio::exit.nok "portal_url ontbreekt. Stel deze in via de add-on configuratie of vul 'manual_wireguard_config' in."
    fi
    if [[ -z "${ENROLLMENT_TOKEN}" ]]; then
        bashio::exit.nok "enrollment_token ontbreekt. Stel deze in via de add-on configuratie of vul 'manual_wireguard_config' in."
    fi
    if [[ "${PORTAL_URL}" != http://* && "${PORTAL_URL}" != https://* ]]; then
        bashio::log.info "Geen protocol gevonden in portal_url; 'https://' wordt toegevoegd."
        PORTAL_URL="https://${PORTAL_URL}"
    fi
    PORTAL_URL="${PORTAL_URL%/}"
    if [[ "${VERIFY_SSL}" != "true" ]]; then
        bashio::log.warning "SSL certificaatcontrole is uitgeschakeld; controleer of je de portal vertrouwt."
    fi
}

fetch_remote_config() {
    local endpoint="${PORTAL_URL}/api/public/clients/${ENROLLMENT_TOKEN}/wireguard-config"
    local -a curl_opts=(
        "--silent"
        "--show-error"
        "--location"
        "--connect-timeout" "10"
        "--max-time" "30"
        "--header" "Accept: application/json"
        "--user-agent" "connect-smart-wireguard-addon/1.1"
        "--write-out" "\n%{http_code}"
    )
    if [[ "${VERIFY_SSL}" != "true" ]]; then
        curl_opts+=("--insecure")
    fi

    bashio::log.info "WireGuard-configuratie ophalen via: ${endpoint}"
    local raw_response http_code
    if ! raw_response=$(curl "${curl_opts[@]}" "${endpoint}" 2>&1); then
        bashio::log.warning "Ophalen van WireGuard-configuratie mislukt (netwerk/verbindingsfout)."
        return 1
    fi

    http_code=$(echo "${raw_response}" | tail -n1)
    response=$(echo "${raw_response}" | head -n-1)

    if [[ "${http_code}" != "200" && "${http_code}" != "201" ]]; then
        bashio::log.warning "Ophalen van WireGuard-configuratie mislukt: HTTP ${http_code}."
        return 1
    fi

    WIREGUARD_CONFIG=$(echo "${response}" | jq -r '.wireguard // empty')
    if [[ -z "${WIREGUARD_CONFIG}" || "${WIREGUARD_CONFIG}" == "null" ]]; then
        local portal_error
        portal_error=$(echo "${response}" | jq -r '.error // empty')
        if [[ -n "${portal_error}" ]]; then
            bashio::log.warning "Portal gaf een fout terug: ${portal_error}"
        else
            bashio::log.warning "Geen geldige WireGuard-configuratie ontvangen van de portal."
        fi
        return 1
    fi

    CLIENT_NAME=$(echo "${response}" | jq -r '.client.name // empty')
    CLIENT_EXTERNAL_URL=$(echo "${response}" | jq -r '.client.external_url // empty')
    LAN_ROUTES=$(echo "${response}" | jq -r '(.lan_cidrs // []) | join(", ")')
}

ensure_persistent_keepalive() {
    local keepalive_value="${1:-25}"
    local keepalive_line="PersistentKeepalive = ${keepalive_value}"
    local output=""
    local in_peer="false"
    local has_keepalive="false"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^[[:space:]]*\[Peer\][[:space:]]*$ ]]; then
            if [[ "${in_peer}" == "true" && "${has_keepalive}" == "false" ]]; then
                output+="${keepalive_line}"$'\n'
            fi
            in_peer="true"
            has_keepalive="false"
        elif [[ "${line}" =~ ^[[:space:]]*\[.*\][[:space:]]*$ ]]; then
            if [[ "${in_peer}" == "true" && "${has_keepalive}" == "false" ]]; then
                output+="${keepalive_line}"$'\n'
            fi
            in_peer="false"
            has_keepalive="false"
        elif [[ "${in_peer}" == "true" && "${line}" =~ ^[[:space:]]*PersistentKeepalive[[:space:]]*= ]]; then
            has_keepalive="true"
        fi

        output+="${line}"$'\n'
    done < <(printf '%s' "${WIREGUARD_CONFIG}")

    if [[ "${in_peer}" == "true" && "${has_keepalive}" == "false" ]]; then
        output+="${keepalive_line}"$'\n'
    fi

    if [[ -n "${output}" && "${output}" != "${WIREGUARD_CONFIG}" ]]; then
        bashio::log.info "PersistentKeepalive=${keepalive_value} toegepast op WireGuard-peer(s)."
    fi

    WIREGUARD_CONFIG="${output:-${WIREGUARD_CONFIG}}"
}

write_config() {
    mkdir -p "${CONFIG_DIR}"
    printf '%s\n' "${WIREGUARD_CONFIG}" > "${TEMP_FILE}"

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        bashio::log.info "Nieuwe WireGuard-configuratie geplaatst."
        mv "${TEMP_FILE}" "${CONFIG_FILE}"
        return
    fi

    if ! cmp -s "${TEMP_FILE}" "${CONFIG_FILE}"; then
        bashio::log.info "WireGuard-configuratie gewijzigd; bestand wordt bijgewerkt."
        mv "${TEMP_FILE}" "${CONFIG_FILE}"
    else
        bashio::log.info "WireGuard-configuratie ongewijzigd."
        rm -f "${TEMP_FILE}"
    fi
}

# ----------------------------------------------------------
# Start configuratie
# ----------------------------------------------------------
load_settings_file
load_addon_options
ensure_inputs
ensure_dns

if [[ -n "${MANUAL_WIREGUARD_CONFIG}" ]]; then
    bashio::log.info "Handmatige WireGuard-configuratie gebruiken (portal wordt niet bevraagd)."
    WIREGUARD_CONFIG="${MANUAL_WIREGUARD_CONFIG}"
elif fetch_remote_config; then
    bashio::log.info "WireGuard-configuratie succesvol opgehaald van portal."
    # Sla op in persistent cache voor gebruik bij toekomstige fouten
    printf '%s\n' "${WIREGUARD_CONFIG}" > "${CACHED_CONFIG_PATH}"
else
    if [[ -f "${CACHED_CONFIG_PATH}" ]]; then
        bashio::log.warning "Portal niet bereikbaar; gecachede configuratie uit /data/ wordt gebruikt."
        WIREGUARD_CONFIG=$(cat "${CACHED_CONFIG_PATH}")
    else
        bashio::exit.nok "Ophalen van WireGuard-configuratie mislukt en er is geen gecachede configuratie beschikbaar."
    fi
fi

if [[ -n "${WIREGUARD_CONFIG}" ]]; then
    ensure_persistent_keepalive "${PERSISTENT_KEEPALIVE}"
    write_config
fi
persist_settings

if [[ -n "${CLIENT_NAME}" ]]; then
    bashio::log.info "Configuratie ontvangen voor client '${CLIENT_NAME}'."
fi
if [[ -n "${CLIENT_EXTERNAL_URL}" ]]; then
    bashio::log.info "Externe URL via portal: ${CLIENT_EXTERNAL_URL}"
fi
if [[ -n "${LAN_ROUTES}" ]]; then
    bashio::log.info "Routes via tunnel: ${LAN_ROUTES}"
fi
