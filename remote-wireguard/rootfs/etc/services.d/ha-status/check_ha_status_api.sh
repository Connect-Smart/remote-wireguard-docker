#!/usr/bin/with-contenv bashio
# ==============================================================================
# Home Assistant Third Party Add-on: WireGuard Client
# Haalt Home Assistant status op via Supervisor API en stuurt naar Remote Portal
# Alternatief voor ha CLI command als die niet beschikbaar is
# ==============================================================================

set -o pipefail

# Supervisor API endpoint
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
ADDON_VERSION=$(bashio::addon.version 2>/dev/null || echo "")

# Trim whitespace
PORTAL_URL=$(echo "${PORTAL_URL}" | xargs)
ENROLLMENT_TOKEN=$(echo "${ENROLLMENT_TOKEN}" | xargs)

# SSL verificatie instelling
if [ "${VERIFY_SSL,,}" = "false" ]; then
    CURL_OPTS="-k"
else
    CURL_OPTS=""
fi

# Controleer enrollment token
if [[ -z "${ENROLLMENT_TOKEN}" ]]; then
    bashio::log.warning "HA Status: geen enrollment_token beschikbaar"
    exit 0
fi

# Portal URL normaliseren
if [[ "${PORTAL_URL}" != http://* && "${PORTAL_URL}" != https://* ]]; then
    PORTAL_URL="https://${PORTAL_URL}"
fi
PORTAL_URL="${PORTAL_URL%/}"

bashio::log.info "HA Status: ophalen via Supervisor API..."

# Haal status op via Supervisor API
CORE_INFO=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/core/info" 2>/dev/null || echo '{"data":{}}')
OS_INFO=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/os/info" 2>/dev/null || echo '{"data":{}}')
SUPERVISOR_INFO=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/supervisor/info" 2>/dev/null || echo '{"data":{}}')
ADDONS_INFO=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/addons" 2>/dev/null || echo '{"data":{"addons":[]}}')
RESOLUTION_INFO=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/resolution/info" 2>/dev/null || echo '{"data":{"issues":[],"suggestions":[]}}')

# Debug logging
bashio::log.debug "Core info: ${CORE_INFO}"
bashio::log.debug "OS info: ${OS_INFO}"
bashio::log.debug "Supervisor info: ${SUPERVISOR_INFO}"
bashio::log.debug "Addons info: ${ADDONS_INFO}"
bashio::log.debug "Resolution info: ${RESOLUTION_INFO}"

# Parse updates (zonder -r voor booleans)
CORE_UPDATE=$(echo "${CORE_INFO}" | jq '.data.update_available // false')
CORE_VERSION=$(echo "${CORE_INFO}" | jq -r '.data.version // "unknown"')
CORE_LATEST=$(echo "${CORE_INFO}" | jq -r '.data.version_latest // "unknown"')

OS_UPDATE=$(echo "${OS_INFO}" | jq '.data.update_available // false')
OS_VERSION=$(echo "${OS_INFO}" | jq -r '.data.version // "unknown"')
OS_LATEST=$(echo "${OS_INFO}" | jq -r '.data.version_latest // "unknown"')

SUPERVISOR_UPDATE=$(echo "${SUPERVISOR_INFO}" | jq '.data.update_available // false')
SUPERVISOR_VERSION=$(echo "${SUPERVISOR_INFO}" | jq -r '.data.version // "unknown"')
SUPERVISOR_LATEST=$(echo "${SUPERVISOR_INFO}" | jq -r '.data.version_latest // "unknown"')

# Parse add-on updates
ADDON_UPDATES=$(echo "${ADDONS_INFO}" | jq '[
    .data.addons[]?
    | select(.update_available == true)
    | {
        name: .name,
        slug: .slug,
        current: .version,
        latest: .version_latest,
        installed: .installed,
        icon: .icon
      }
]')

# Parse repairs/issues
ISSUES=$(echo "${RESOLUTION_INFO}" | jq '[
    .data.issues[]?
    | {
        uuid: .uuid,
        type: .type,
        context: .context,
        reference: .reference
      }
]')

SUGGESTIONS=$(echo "${RESOLUTION_INFO}" | jq '[
    .data.suggestions[]?
    | {
        uuid: .uuid,
        type: .type,
        context: .context,
        reference: .reference
      }
]')

UNHEALTHY=$(echo "${RESOLUTION_INFO}" | jq '.data.unhealthy // []')

# Bouw JSON payload
PAYLOAD=$(jq -n \
  --argjson core_update "${CORE_UPDATE}" \
  --arg core_version "${CORE_VERSION}" \
  --arg core_latest "${CORE_LATEST}" \
  --argjson os_update "${OS_UPDATE}" \
  --arg os_version "${OS_VERSION}" \
  --arg os_latest "${OS_LATEST}" \
  --argjson supervisor_update "${SUPERVISOR_UPDATE}" \
  --arg supervisor_version "${SUPERVISOR_VERSION}" \
  --arg supervisor_latest "${SUPERVISOR_LATEST}" \
  --argjson addon_updates "${ADDON_UPDATES}" \
  --argjson issues "${ISSUES}" \
  --argjson suggestions "${SUGGESTIONS}" \
  --argjson unhealthy "${UNHEALTHY}" \
  '{
    updates: {
      core: (if $core_update then {current: $core_version, latest: $core_latest} else null end),
      os: (if $os_update then {current: $os_version, latest: $os_latest} else null end),
      supervisor: (if $supervisor_update then {current: $supervisor_version, latest: $supervisor_latest} else null end),
      addons: $addon_updates
    },
    repairs: {
      issues: $issues,
      suggestions: $suggestions,
      unhealthy: $unhealthy
    },
    timestamp: now
  }')

# Valideer payload
if [[ -z "${PAYLOAD}" || "${PAYLOAD}" == "null" ]]; then
    bashio::log.error "HA Status: payload is leeg, skip verzenden"
    exit 1
fi

# Valideer JSON
if ! echo "${PAYLOAD}" | jq empty 2>/dev/null; then
    bashio::log.error "HA Status: payload is geen geldige JSON"
    bashio::log.debug "Invalid payload: ${PAYLOAD}"
    exit 1
fi

bashio::log.debug "HA Status payload: ${PAYLOAD}"
bashio::log.info "HA Status: versturen naar portal..."

# Stuur naar portal met correcte curl opties
if [ "${VERIFY_SSL,,}" = "false" ]; then
    RESPONSE=$(curl -s -w "\n%{http_code}" -k -X POST "${PORTAL_URL}/api/ha-status/push" -H "Authorization: Bearer ${ENROLLMENT_TOKEN}" -H "Content-Type: application/json" -H "X-Addon-Version: ${ADDON_VERSION}" -d "${PAYLOAD}")
else
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${PORTAL_URL}/api/ha-status/push" -H "Authorization: Bearer ${ENROLLMENT_TOKEN}" -H "Content-Type: application/json" -H "X-Addon-Version: ${ADDON_VERSION}" -d "${PAYLOAD}")
fi

HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
RESPONSE_BODY=$(echo "${RESPONSE}" | head -n-1)

if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "201" ]; then
    bashio::log.info "HA Status: succesvol verstuurd naar portal"
else
    bashio::log.warning "HA Status: fout bij versturen: HTTP ${HTTP_CODE}"
    bashio::log.debug "HA Status response: ${RESPONSE_BODY}"
fi
