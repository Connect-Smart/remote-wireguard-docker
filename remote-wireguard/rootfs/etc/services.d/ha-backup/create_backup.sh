#!/usr/bin/with-contenv bashio
# ==============================================================================
# Home Assistant Third Party Add-on: WireGuard Client
# Maakt een HA backup en uploadt deze naar de Remote Portal (10.8.0.1)
# ==============================================================================

set -o pipefail

SUPERVISOR_API="http://supervisor"
SUPERVISOR_TOKEN="${SUPERVISOR_TOKEN}"

# Configuratie ophalen
get_config_value() {
    local key="${1}"
    local default="${2}"
    local value="${default}"

    if bashio::config.has_value "advanced.${key}"; then
        value=$(bashio::config "advanced.${key}")
    elif bashio::config.has_value "${key}"; then
        value=$(bashio::config "${key}")
    fi

    echo "${value}"
}

PORTAL_URL=$(get_config_value "portal_url" "https://remote.connect-smart.nl")
ENROLLMENT_TOKEN=$(bashio::config "enrollment_token")
VERIFY_SSL=$(get_config_value "verify_ssl" "true")
BACKUP_RETAIN=$(get_config_value "backup_retain" "3")
ADDON_VERSION=$(bashio::addon.version 2>/dev/null || echo "")

# Trim whitespace
PORTAL_URL=$(echo "${PORTAL_URL}" | xargs)
ENROLLMENT_TOKEN=$(echo "${ENROLLMENT_TOKEN}" | xargs)

# Controleer enrollment token
if [[ -z "${ENROLLMENT_TOKEN}" ]]; then
    bashio::log.warning "Backup: geen enrollment_token beschikbaar, overslaan"
    exit 0
fi

# Portal URL normaliseren
if [[ "${PORTAL_URL}" != http://* && "${PORTAL_URL}" != https://* ]]; then
    PORTAL_URL="https://${PORTAL_URL}"
fi
PORTAL_URL="${PORTAL_URL%/}"

# SSL verificatie instelling
if [ "${VERIFY_SSL,,}" = "false" ]; then
    CURL_OPTS="-k"
else
    CURL_OPTS=""
fi

send_notification() {
    local level="${1}"   # error | warning | info
    local message="${2}"

    local payload
    payload=$(jq -n \
        --arg level "${level}" \
        --arg message "${message}" \
        --arg source "ha-backup" \
        '{level: $level, message: $message, source: $source, timestamp: now}')

    if [ "${VERIFY_SSL,,}" = "false" ]; then
        curl -s -k -X POST "${PORTAL_URL}/api/notifications/push" \
            -H "Authorization: Bearer ${ENROLLMENT_TOKEN}" \
            -H "Content-Type: application/json" \
            -H "X-Addon-Version: ${ADDON_VERSION}" \
            -d "${payload}" > /dev/null 2>&1
    else
        curl -s -X POST "${PORTAL_URL}/api/notifications/push" \
            -H "Authorization: Bearer ${ENROLLMENT_TOKEN}" \
            -H "Content-Type: application/json" \
            -H "X-Addon-Version: ${ADDON_VERSION}" \
            -d "${payload}" > /dev/null 2>&1
    fi
}

bashio::log.info "Backup: aanmaken van volledige Home Assistant backup..."

# Start backup via Supervisor API
BACKUP_RESPONSE=$(curl -s \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST \
    "${SUPERVISOR_API}/backups/new/full" \
    -d '{"name":"remote-portal-backup"}' 2>/dev/null)

if [[ -z "${BACKUP_RESPONSE}" ]]; then
    bashio::log.error "Backup: geen reactie van Supervisor API"
    send_notification "error" "Backup mislukt: geen reactie van Supervisor API"
    exit 1
fi

BACKUP_SLUG=$(echo "${BACKUP_RESPONSE}" | jq -r '.data.slug // empty')
BACKUP_RESULT=$(echo "${BACKUP_RESPONSE}" | jq -r '.result // empty')

if [[ "${BACKUP_RESULT}" != "ok" || -z "${BACKUP_SLUG}" ]]; then
    error_msg=$(echo "${BACKUP_RESPONSE}" | jq -r '.message // "onbekende fout"')
    bashio::log.error "Backup: aanmaken mislukt: ${error_msg}"
    send_notification "error" "Backup mislukt: ${error_msg}"
    exit 1
fi

bashio::log.info "Backup: aangemaakt met slug '${BACKUP_SLUG}', uploaden naar portal..."

# Backup bestand ophalen en uploaden
BACKUP_FILE="/backup/${BACKUP_SLUG}.tar"

if [[ ! -f "${BACKUP_FILE}" ]]; then
    bashio::log.error "Backup: bestand niet gevonden: ${BACKUP_FILE}"
    exit 1
fi

BACKUP_SIZE=$(du -sh "${BACKUP_FILE}" | cut -f1)
bashio::log.info "Backup: bestandsgrootte ${BACKUP_SIZE}, uploaden naar ${PORTAL_URL}..."

# Upload naar portal via enrollment token
if [ "${VERIFY_SSL,,}" = "false" ]; then
    UPLOAD_RESPONSE=$(curl -s -w "\n%{http_code}" -k \
        -X POST "${PORTAL_URL}/api/backup/upload" \
        -H "Authorization: Bearer ${ENROLLMENT_TOKEN}" \
        -H "X-Addon-Version: ${ADDON_VERSION}" \
        -F "backup=@${BACKUP_FILE};type=application/x-tar" \
        -F "slug=${BACKUP_SLUG}" \
        --max-time 600)
else
    UPLOAD_RESPONSE=$(curl -s -w "\n%{http_code}" \
        -X POST "${PORTAL_URL}/api/backup/upload" \
        -H "Authorization: Bearer ${ENROLLMENT_TOKEN}" \
        -H "X-Addon-Version: ${ADDON_VERSION}" \
        -F "backup=@${BACKUP_FILE};type=application/x-tar" \
        -F "slug=${BACKUP_SLUG}" \
        --max-time 600)
fi

HTTP_CODE=$(echo "${UPLOAD_RESPONSE}" | tail -n1)
RESPONSE_BODY=$(echo "${UPLOAD_RESPONSE}" | head -n-1)

UPLOAD_FAILED=false
if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "201" ]; then
    bashio::log.info "Backup: succesvol geüpload naar portal (${BACKUP_SLUG})"
    send_notification "info" "Backup succesvol geüpload naar portal (slug: ${BACKUP_SLUG})"
else
    bashio::log.warning "Backup: upload mislukt: HTTP ${HTTP_CODE}"
    bashio::log.debug "Backup upload response: ${RESPONSE_BODY}"
    send_notification "error" "Backup upload mislukt: HTTP ${HTTP_CODE} (slug: ${BACKUP_SLUG})"
    UPLOAD_FAILED=true
fi

# Oude lokale backups altijd opruimen (ook bij mislukte upload), bewaar de laatste N
bashio::log.info "Backup: opruimen oude backups (bewaar laatste ${BACKUP_RETAIN})..."

BACKUPS_RESPONSE=$(curl -s \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    "${SUPERVISOR_API}/backups" 2>/dev/null)

BACKUP_SLUGS=$(echo "${BACKUPS_RESPONSE}" | jq -r \
    '[.data.backups[] | select(.name == "remote-portal-backup") | {slug, date}]
     | sort_by(.date) | reverse | .['"${BACKUP_RETAIN}"':] | .[].slug' 2>/dev/null)

if [[ -n "${BACKUP_SLUGS}" ]]; then
    while IFS= read -r old_slug; do
        bashio::log.info "Backup: verwijderen oude backup '${old_slug}'"
        curl -s \
            -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            -X DELETE \
            "${SUPERVISOR_API}/backups/${old_slug}" > /dev/null 2>&1
    done <<< "${BACKUP_SLUGS}"
fi

bashio::log.info "Backup: klaar"

if [[ "${UPLOAD_FAILED}" == "true" ]]; then
    exit 1
fi
