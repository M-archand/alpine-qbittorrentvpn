#!/bin/bash
# Docker HEALTHCHECK (see Dockerfile). Exit 0 = healthy, 1 = unhealthy. stdout is kept by Docker under
# .State.Health.Log, so 'docker inspect' shows why the container is unhealthy without reading its log.
#
#   unhealthy  fail_init()/trip_kill_switch() parked the container (failed init, tripped kill switch), STOP_MARKER holds the reason
#   unhealthy  qBittorrent's s6 service is not up (still booting, covered by --start-period, or crashed)
#   healthy    otherwise

# shellcheck disable=SC1091
source /scripts/helper/functions.sh

if [[ -f "${STOP_MARKER}" ]]; then
    echo "Container parked: $(cat "${STOP_MARKER}")"
    exit 1
fi

# 'docker exec' does not have /command on PATH, so the s6 binary is called by its full path
if [[ "$(/command/s6-svstat -o up /run/service/service-qbittorrent 2>/dev/null)" != "true" ]]; then
    echo "qBittorrent service is not up"
    exit 1
fi

echo "qBittorrent service is up"
