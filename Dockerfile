# Unturned dedicated server image for Flux.
#
# Written from scratch. The game's native Linux server (Steam app 1110390, "U3DS"), installed and
# updated with SteamCMD on every start, under a supervisor that writes Commands.dat and the
# Workshop list from the environment (the server takes its name, map, player limit, password,
# port and Game Server Login Token from nowhere else), saves the world on a timer and on stop
# (Unturned has no autosave of its own), and restarts the server in place. See README.md.
FROM steamcmd/steamcmd:ubuntu-24

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUX_IMAGE_VERSION=dev

# python3, NOT python3-minimal: flux-config.py needs json. tests/test-image.sh runs the scripts
# inside the image. The rest is what the Unity headless player loads.
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl procps tzdata python3 libgdiplus && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/flux-console.sh scripts/flux-config.py /opt/flux/
RUN chmod 0755 /opt/flux/*.sh /opt/flux/*.py && \
    ln -s /opt/flux/flux-console.sh /usr/local/bin/flux-console

# SteamCMD's self-update, done once here instead of on every container start; the weekly
# rebuild keeps it current.
RUN steamcmd +quit >/dev/null 2>&1; test -d /root/.local/share/Steam

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION}

VOLUME ["/mnt/unturned/server", "/mnt/unturned/data"]

# Two consecutive UDP ports: the first (FLUX_PORT, 27015) for the server list's queries, the next
# for the game itself.
EXPOSE 27015/udp 27016/udp

# The first start downloads about 2 GB. FluxOS does not act on health; this is for anyone running
# the image by hand.
HEALTHCHECK --interval=60s --timeout=10s --start-period=30m --retries=3 \
    CMD pgrep -f Unturned_Headless.x86_64 >/dev/null || exit 1

ENTRYPOINT []
CMD ["/opt/flux/flux-entrypoint.sh"]
