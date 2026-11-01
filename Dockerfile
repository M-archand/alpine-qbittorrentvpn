# Base images are pinned by digest. Dependabot (.github/dependabot.yml) proposes updates
FROM golang:1.27-alpine@sha256:d200d2dd76b03a99b52651fd1325aff7dcd35422c35c01bac56571b0507f3deb AS go-builder

WORKDIR /app

COPY build/dwk/go.mod build/dwk/main.go ./
RUN \
    go mod download; \
    CGO_ENABLED=0 GOOS=linux go build -o ./dwk


FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

# Exit if one of the cont-init.d scripts fails
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2
ENV S6_STAGE2_HOOK=/scripts/helper/setup-custom-s6.sh

RUN \
    # Install tools
    apk add --no-cache \
        bash \
        bind-tools \
        curl \
        dos2unix \
        grep \
        ipcalc \
        iproute2 \
        iputils \
        nftables \
        openresolv \
        openssl \
        openvpn \
        sed \
        tzdata \
        wget \
        wireguard-go \
        wireguard-tools-wg-quick;

COPY ./build/build-scripts /tmp/build-scripts
# You can find the available release tags at https://github.com/just-containers/s6-overlay/releases
ARG S6_OVERLAY_TAG="v3.2.2.0"
RUN \
    # Install s6-overlay, each tarball is verified against its upstream SHA-256 checksum
    /bin/sh /tmp/build-scripts/fetch-release-asset just-containers/s6-overlay "${S6_OVERLAY_TAG}" "s6-overlay-$(/bin/sh /tmp/build-scripts/s6-overlay-arch).tar.xz" /tmp/s6_overlay.tar.xz && \
    /bin/sh /tmp/build-scripts/fetch-release-asset just-containers/s6-overlay "${S6_OVERLAY_TAG}" s6-overlay-noarch.tar.xz /tmp/s6_overlay-noarch.tar.xz && \
    tar -C / -Jxpf /tmp/s6_overlay.tar.xz && \
    tar -C / -Jxpf /tmp/s6_overlay-noarch.tar.xz

ARG QBITTORRENT_TAG
RUN \
    # Install qbittorrent-nox (latest release when QBITTORRENT_TAG is empty), verified against its upstream SHA-256 checksum
    /bin/sh /tmp/build-scripts/fetch-release-asset userdocs/qbittorrent-nox-static "${QBITTORRENT_TAG:-latest}" "$(/bin/sh /tmp/build-scripts/qbittorrent-nox-static-arch)-qbittorrent-nox" /bin/qbittorrent-nox && \
    chmod +x /bin/qbittorrent-nox

COPY rootfs /

RUN \
    # Add go binaries from go-builder stage
    --mount=type=bind,from=go-builder,src=/app/,dst=/mnt/go-builder/ \
    cp /mnt/go-builder/dwk /scripts/helper/dwk

RUN \
    # Set exec permissions
    chmod +x -R /scripts/ /etc/s6-overlay && \
    # Rename wg-quick to bypass AppArmor profile on Ubuntu 25.10+
    # Ubuntu ships an AppArmor profile for wg-quick that blocks readlink
    # via BusyBox symlinks inside Alpine containers
    mv /usr/bin/wg-quick /usr/bin/wg-quick-custom && \
    # Remove temporary files
    rm -r /tmp/*

ARG SOURCE_COMMIT="UNSPECIFIED"
RUN \
    echo "${SOURCE_COMMIT}" > /etc/image-source-commit; \
    echo "$(date +'%Y-%m-%d %H:%M:%S')" > /etc/image-build-date

VOLUME /config /downloads
EXPOSE 8080

# Unhealthy while the container is parked by fail_init()/trip_kill_switch() (failed init, tripped kill switch) or
# qBittorrent is not up, see rootfs/scripts/helper/healthcheck.sh. Failures inside start-period (tunnel coming up) do not count.
HEALTHCHECK --interval=20s --timeout=5s --start-period=60s --retries=2 CMD ["/scripts/helper/healthcheck.sh"]

CMD ["/init"]
