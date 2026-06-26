ARG BUILD_FROM=ghcr.io/hassio-addons/base:17.2.4
# hadolint ignore=DL3006
FROM ${BUILD_FROM}

# Set shell
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Setup base
# # Install build dependencies
# RUN apk add --no-cache --virtual .build-dependencies \
#       build-base \
#       git

# Install runtime dependencies
RUN apk add --no-cache \
      iptables \
      jq \
      curl \
      libqrencode-tools \
      openresolv \
      wireguard-tools

# # Build wireguard-go from source
# RUN git clone --depth=1 https://git.zx2c4.com/wireguard-go /tmp/wireguard-go && \
#     cd /tmp/wireguard-go && \
#     make && \
#     install -Dm755 wireguard-go /usr/local/bin/wireguard-go && \
#     rm -rf /tmp/wireguard-go

# Link iptables wrapper
RUN ln -sf /sbin/xtables-nft-multi /sbin/ip6tables && \
    ln -sf /sbin/xtables-nft-multi /sbin/iptables

# # Cleanup build dependencies
# RUN apk del .build-dependencies && \
#     rm -rf /var/cache/apk/*

# Copy root filesystem
COPY rootfs /

RUN chmod +x /etc/services.d/wireguard_client/run
RUN chmod +x /etc/services.d/api/run
RUN chmod +x /etc/services.d/status/run
RUN chmod +x /etc/services.d/ha-status/run
RUN chmod +x /etc/services.d/ha-status/log/run
RUN chmod +x /etc/services.d/ha-status/check_ha_status_api.sh
RUN chmod +x /etc/services.d/ha-backup/run
RUN chmod +x /etc/services.d/ha-backup/log/run
RUN chmod +x /etc/services.d/ha-backup/create_backup.sh
RUN chmod +x /etc/cont-finish.d/00-stop
RUN chmod +x /etc/cont-init.d/config.sh
RUN chmod +x /etc/cont-init.d/10-log-level.sh


# Build arguments
ARG BUILD_ARCH
ARG BUILD_DATE
ARG BUILD_DESCRIPTION
ARG BUILD_NAME
ARG BUILD_REF
ARG BUILD_REPOSITORY
ARG BUILD_VERSION

# Labels
LABEL \
    io.hass.name="WireGuard Client" \
    io.hass.description="Connect-Smart WireGuard client for Remote Portal" \
    io.hass.arch="${BUILD_ARCH}" \
    io.hass.type="addon" \
    io.hass.version=${BUILD_VERSION} \
    maintainer="Jos Rothman <jos@connect-smart.nl>" \
    org.opencontainers.image.title="WireGuard Client" \
    org.opencontainers.image.description="Connect-Smart WireGuard client for Remote Portal" \
    org.opencontainers.image.vendor="Home Assistant Connect-Smart WG Add-on" \
    org.opencontainers.image.authors="Jos Rothman <jos@connect-smart.nl>" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.url="https://github.com/Connect-Smart/remote-wireguard/" \
    org.opencontainers.image.source="https://github.com/Connect-Smart/remote-wireguard/-/blob/main/remote-wireguard" \
    org.opencontainers.image.documentation="https://github.com/Connect-Smart/remote-wireguard/-/blob/main/remote-wireguard/README.md" \
    org.opencontainers.image.created=${BUILD_DATE} \
    org.opencontainers.image.revision=${BUILD_REF} \
    org.opencontainers.image.version=${BUILD_VERSION}
