#!/bin/bash
set -e

cleanup() {
    docker compose -f tests/docker-compose-wg-e2e.yml down --volumes --remove-orphans || true
}

if [[ "$1" == "--build" ]]; then
    echo "Building qbittorrentvpn:test"
    docker build -t qbittorrentvpn:test .
fi

echo "Cleaning up any old state..."
cleanup

echo "Starting wireguard..."
docker compose -f tests/docker-compose-wg-e2e.yml up -d wireguard

# Wait for wireguard config to be generated
MAX_W_WAIT=30
W_WAIT=0
while ! docker exec wireguard sh -c "test -f /config/peer1/peer1.conf" && [ $W_WAIT -lt $MAX_W_WAIT ]; do
    echo "Waiting for wg-config..."
    sleep 2
    ((W_WAIT+=2))
done

if ! docker exec wireguard sh -c "test -f /config/peer1/peer1.conf"; then
    echo "Failed to generate wireguard configuration"
    exit 1
fi

# The container must not touch the mounted config (it works on a copy under /run)
WG_CONF_SUM_BEFORE=$(docker exec wireguard md5sum /config/peer1/peer1.conf)

echo "Starting qbittorrentvpn..."
docker compose -f tests/docker-compose-wg-e2e.yml up -d qbittorrentvpn

# Wait for qBittorrent WebUI to become responsive
echo "Waiting for qbittorrent WebUI..."
MAX_Q_WAIT=60
Q_WAIT=0
while ! curl -s "http://127.0.0.1:8080/api/v2/app/version" > /dev/null; do
    echo "Waiting for API to be responsive..."
    sleep 2
    ((Q_WAIT+=2))
    if [ $Q_WAIT -gt $MAX_Q_WAIT ]; then
        echo "Timeout waiting for WebUI"
        docker logs qbittorrentvpn
        exit 1
    fi
done

echo "Waiting for the container to report healthy..."
MAX_H_WAIT=60
H_WAIT=0
while [ "$(docker inspect --format '{{.State.Health.Status}}' qbittorrentvpn)" != "healthy" ]; do
    sleep 2
    ((H_WAIT+=2))
    if [ $H_WAIT -gt $MAX_H_WAIT ]; then
        echo "Timeout waiting for the container to become healthy"
        docker inspect --format '{{json .State.Health}}' qbittorrentvpn
        docker logs qbittorrentvpn
        cleanup
        exit 1
    fi
done
echo "Container is healthy"

echo "Checking that the mounted WireGuard config was left untouched..."
WG_CONF_SUM_AFTER=$(docker exec wireguard md5sum /config/peer1/peer1.conf)
if [ "$WG_CONF_SUM_BEFORE" != "$WG_CONF_SUM_AFTER" ] || ! docker exec qbittorrentvpn test -f /run/wireguard/wg0.conf; then
    echo "Mounted config changed (${WG_CONF_SUM_BEFORE} -> ${WG_CONF_SUM_AFTER}) or working copy /run/wireguard/wg0.conf missing"
    docker logs qbittorrentvpn
    cleanup
    exit 1
fi
echo "Mounted config unchanged, working copy present"

echo "Authenticating..."
COOKIE=$(curl -i --header "Referer: http://127.0.0.1:8080" --data "username=admin&password=adminadmin" http://127.0.0.1:8080/api/v2/auth/login | grep "set-cookie" | awk '{print $2}')
if [ -z "$COOKIE" ]; then
    echo "Failed to authenticate"
    exit 1
fi

PREFS=$(curl -s -H "Cookie: ${COOKIE}" http://127.0.0.1:8080/api/v2/app/preferences)

echo "Checking that Host header validation is on (shipped template)..."
if ! grep -q '"web_ui_host_header_validation_enabled":true' <<< "$PREFS"; then
    echo "qBittorrent reports Host header validation off: $(grep -o '"web_ui_host_header_validation_enabled":[a-z]*' <<< "$PREFS")"
    docker exec qbittorrentvpn grep -n 'HostHeaderValidation' /config/qBittorrent/config/qBittorrent.conf || true
    cleanup
    exit 1
fi
echo "Host header validation is on"

echo "Checking that qBittorrent is bound to the VPN interface..."
BOUND_IFACE=$(grep -o '"current_network_interface":"[^"]*"' <<< "$PREFS" | cut -d'"' -f4)
if [ "$BOUND_IFACE" != "wg0" ] || ! docker exec qbittorrentvpn grep -Fxq 'Session\Interface=wg0' /config/qBittorrent/config/qBittorrent.conf; then
    echo "qBittorrent is not bound to wg0 (API reports '${BOUND_IFACE}')"
    docker exec qbittorrentvpn grep -n 'Interface' /config/qBittorrent/config/qBittorrent.conf || true
    docker logs qbittorrentvpn
    cleanup
    exit 1
fi
echo "qBittorrent is bound to interface: $BOUND_IFACE"

echo "Checking that qBittorrent runs as PUID:PGID..."

QBT_IDS=$(docker exec qbittorrentvpn sh -c 'awk "/^Uid:/{u=\$2} /^Gid:/{g=\$2} END{print u\":\"g}" /proc/$(pidof qbittorrent-nox)/status')
QBT_LOG_OWNER=$(docker exec qbittorrentvpn stat -c '%u:%g' /config/qBittorrent/data/logs/qbittorrent.log)
if [ "$QBT_IDS" != "99:100" ] || [ "$QBT_LOG_OWNER" != "99:100" ]; then
    echo "qBittorrent runs as '${QBT_IDS}' and its log is owned by '${QBT_LOG_OWNER}', expected 99:100"
    docker logs qbittorrentvpn
    cleanup
    exit 1
fi
echo "qBittorrent runs as ${QBT_IDS}, log owned by ${QBT_LOG_OWNER}"

echo "Checking that the kill switch blocks the docker interface..."
if ! docker exec qbittorrentvpn nft list chain inet qbt-firewall output | grep -q 'policy drop;'; then
    echo "nftables chain inet qbt-firewall output with policy drop is missing"
    docker exec qbittorrentvpn nft list ruleset || true
    cleanup
    exit 1
fi
if docker exec qbittorrentvpn ping -w 2 -c 1 -I eth0 1.1.1.1 > /dev/null 2>&1; then
    echo "ICMP echo to 1.1.1.1 over eth0 succeeded, the kill switch leaks"
    cleanup
    exit 1
fi
CONNECT_TIME=$(docker exec qbittorrentvpn curl --interface 'if!eth0' --connect-timeout 2 --max-time 3 -s -o /dev/null -w '%{time_connect}' http://1.1.1.1:53 || true)
if [ "$CONNECT_TIME" != "0.000000" ]; then
    echo "TCP connection to 1.1.1.1:53 over eth0 succeeded (time_connect=${CONNECT_TIME}), the kill switch leaks"
    cleanup
    exit 1
fi
echo "Kill switch holds: nftables policy drop present, ICMP and TCP over eth0 blocked"

echo "Adding test magnet link..."
curl -s -X POST -H "Cookie: ${COOKIE}" --data "urls=magnet:?xt=urn:btih:31337..." http://127.0.0.1:8080/api/v2/torrents/add

echo "Waiting for connection status..."
MAX_C_WAIT=60
C_WAIT=0
SUCCESS=false

while [ $C_WAIT -lt $MAX_C_WAIT ]; do
    STATUS=$(curl -s -H "Cookie: ${COOKIE}" http://127.0.0.1:8080/api/v2/sync/maindata | grep -o '"connection_status":"[^"]*"' | cut -d'"' -f4)
    if [ "$STATUS" == "connected" ] || [ "$STATUS" == "firewalled" ]; then
        echo "Connection established! Status: $STATUS"
        SUCCESS=true
        break
    fi
    echo "Current status: $STATUS"
    sleep 2
    ((C_WAIT+=2))
done

if [ "$SUCCESS" != "true" ]; then
    echo "Failed to establish VPN connection"
    docker logs qbittorrentvpn
    cleanup
    exit 1
fi

echo "Tripping the kill switch (deleting the nftables table)..."
docker exec qbittorrentvpn nft delete table inet qbt-firewall

# firewall-check must call trip_kill_switch: qBittorrent and both check services down, container still up with no
# restart (connectivity-check's finish must not halt), health unhealthy with the reason
MAX_T_WAIT=150
T_WAIT=0
while [ "$(docker inspect --format '{{.State.Health.Status}}' qbittorrentvpn)" != "unhealthy" ]; do
    sleep 2
    ((T_WAIT+=2))
    if [ $T_WAIT -gt $MAX_T_WAIT ]; then
        echo "Timeout waiting for the container to become unhealthy after the kill-switch trip"
        docker inspect --format '{{json .State.Health}}' qbittorrentvpn
        docker logs qbittorrentvpn
        cleanup
        exit 1
    fi
done
HEALTH_OUTPUT=$(docker inspect --format '{{range .State.Health.Log}}{{println .Output}}{{end}}' qbittorrentvpn | grep . | tail -n 1)
RESTARTS=$(docker inspect --format '{{.RestartCount}}' qbittorrentvpn)
FW_UP=$(docker exec qbittorrentvpn /command/s6-svstat -o up /run/service/service-firewall-check)
CC_UP=$(docker exec qbittorrentvpn /command/s6-svstat -o up /run/service/service-connectivity-check)
if [ "$(docker inspect --format '{{.State.Status}}' qbittorrentvpn)" != "running" ] || [ "$RESTARTS" != "0" ] || [ "$FW_UP" != "false" ] || [ "$CC_UP" != "false" ] || docker exec qbittorrentvpn pidof qbittorrent-nox > /dev/null 2>&1 || ! echo "$HEALTH_OUTPUT" | grep -q "Firewall is down"; then
    echo "Expected a running container with 0 restarts, qbittorrent-nox and both check services down and a health output naming the trip, got: restarts=${RESTARTS} firewall-check up=${FW_UP} connectivity-check up=${CC_UP} health=${HEALTH_OUTPUT}"
    docker inspect --format '{{json .State}}' qbittorrentvpn
    docker logs qbittorrentvpn
    cleanup
    exit 1
fi
echo "Kill-switch trip parked the container: unhealthy, 0 restarts, qBittorrent and check services stopped, reason: ${HEALTH_OUTPUT}"

echo "Test completed successfully"
cleanup
exit 0