FROM alpine:3.19

RUN apk add --no-cache \
    openvpn \
    wireguard-tools \
    dante-server \
    linux-pam \
    curl \
    iptables \
    ip6tables \
    bash \
    bind-tools \
    openresolv \
    gettext

RUN mkdir -p /app /config

COPY entrypoint.sh healthcheck.sh /app/
COPY sockd.conf.template /app/
RUN chmod +x /app/entrypoint.sh /app/healthcheck.sh

EXPOSE 1080

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD /app/healthcheck.sh

ENTRYPOINT ["/app/entrypoint.sh"]
