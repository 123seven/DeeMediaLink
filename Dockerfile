# syntax=docker/dockerfile:1
# Binaries are produced locally and supplied as verified Release assets.
FROM alpine:3.23
ARG TARGETARCH
# Alpine includes placeholder directories under /media; discovery should only
# see directories supplied by the deployment.
RUN apk add --no-cache ca-certificates \
    && rm -rf /media \
    && mkdir -p /data /media \
    && chown 1000:1000 /data
COPY deemedia-link-linux-${TARGETARCH} /usr/local/bin/deemedia-link
COPY entrypoint.sh /usr/local/bin/deemedia-link-supervisor
RUN chmod 0755 /usr/local/bin/deemedia-link /usr/local/bin/deemedia-link-supervisor
WORKDIR /
ENV DEEMEDIA_LINK_DATA=/data \
    DEEMEDIA_LINK_MEDIA_DIR=/media \
    DEEMEDIA_LINK_ADDR=:8097 \
    DEEMEDIA_LINK_PROBE_DIR=/tmp/deemedia-link-tools
EXPOSE 8097
VOLUME ["/data"]
USER 1000:1000
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s CMD ["/usr/local/bin/deemedia-link", "--probe"]
ENTRYPOINT ["/usr/local/bin/deemedia-link-supervisor"]
