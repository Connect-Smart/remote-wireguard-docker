#!/usr/bin/with-contenv bashio
# ==============================================================================
# Home Assistant Third Party Add-on: WireGuard Client
# Configures the global log level based on add-on options.
# ==============================================================================

DEFAULT_LOG_LEVEL="warning"
LOG_LEVEL="${DEFAULT_LOG_LEVEL}"

if bashio::config.has_value "log_level"; then
    LOG_LEVEL="$(bashio::config 'log_level')"
fi

bashio::log.level "${LOG_LEVEL}"
bashio::log.info "Logniveau ingesteld op ${LOG_LEVEL}"
