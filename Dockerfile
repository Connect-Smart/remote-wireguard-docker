FROM alpine:3.19

RUN apk add --no-cache \
    bash \
    curl \
    ip6tables \
    iptables \
    jq \
    openresolv \
    wireguard-tools

COPY entrypoint.sh /entrypoint.sh
COPY watchdog.sh /watchdog.sh
RUN chmod +x /entrypoint.sh /watchdog.sh

ENV PORTAL_URL="https://remote.connect-smart.nl"
ENV ENROLLMENT_TOKEN=""
ENV VERIFY_SSL="true"
ENV MONITOR_TARGET="10.8.0.1"
ENV MONITOR_INTERVAL="30"
ENV PERSISTENT_KEEPALIVE="25"
ENV MANUAL_WIREGUARD_CONFIG=""
ENV PORT_FORWARDS=""

ENTRYPOINT ["/entrypoint.sh"]
