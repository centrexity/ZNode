ARG ZEBRA_VERSION=6.4.2
ARG CLOUDFLARED_VERSION=2026.10.0

FROM cloudflare/cloudflared:${CLOUDFLARED_VERSION} AS tunnel
FROM zfnd/zebra:${ZEBRA_VERSION}

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates jq supervisor && \
    rm -rf /var/lib/apt/lists/*

COPY --from=tunnel /usr/local/bin/cloudflared /usr/local/bin/cloudflared
COPY entrypoint.sh /usr/local/bin/znode-entrypoint
COPY rpc.sh /usr/local/bin/znode-rpc
COPY healthcheck.sh /usr/local/bin/znode-healthcheck
COPY supervisord.conf /etc/znode-supervisord.conf
RUN chmod 755 /usr/local/bin/znode-entrypoint /usr/local/bin/znode-rpc \
    /usr/local/bin/znode-healthcheck

VOLUME ["/zcash", "/config"]
LABEL org.opencontainers.image.source="https://github.com/centrexity/ZNode" \
      org.opencontainers.image.title="ZNode"
HEALTHCHECK --interval=60s --timeout=10s --start-period=120s \
    CMD ["/usr/local/bin/znode-healthcheck"]
ENTRYPOINT ["/usr/local/bin/znode-entrypoint"]
CMD []
