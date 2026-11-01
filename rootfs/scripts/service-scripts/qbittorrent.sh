#!/command/with-contenv bash
# shellcheck shell=bash

# shellcheck disable=SC1091
source /scripts/helper/functions.sh

QBITTORRENTLOGPATH="/config/qBittorrent/data/logs"
QBITTORRENTLOG="qbittorrent.log"
DAEMON="qbittorrent-nox"

umask "${UMASK}"

# qBittorrent writes its own log here; its stdout/stderr stays attached to the
# s6 service so startup crashes are visible in the container log.
if [ ! -e "$QBITTORRENTLOGPATH" ]; then
	mkdir -p "$QBITTORRENTLOGPATH"
	chown -R "${PUID}":"${PGID}" /config/qBittorrent
fi

log_info "qBittorrent writes its own log to $QBITTORRENTLOGPATH/$QBITTORRENTLOG. Startup/crash output is shown below and in the container log."

# Check that the kill switch is in place and cannot be bypassed
if [[ $VPN_ENABLED != "no" ]]; then
	log_info "Checking the kill switch: nftables rules present, $HEALTH_CHECK_HOST and $FIREWALL_CHECK_HOST unreachable over the docker interface (ICMP and TCP)..."

	if ! firewall_rules_intact || firewall_bypassed; then
		log_error "Firewall is down!"
		stop_container
	else
		log_info "Success: Could not connect. This means the firewall is most likely working properly."
	fi
fi

# Exec directly (no wrapping shell) so qbittorrent-nox is the process s6
# supervises and receives SIGTERM on shutdown, exiting cleanly.
# Numeric uid:gid so PGID applies regardless of the account's primary group.
exec s6-setuidgid "${PUID}:${PGID}" "$DAEMON" --profile=/config
