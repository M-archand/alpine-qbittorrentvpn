#!/command/with-contenv bash
# shellcheck shell=bash

# shellcheck disable=SC1091
source /scripts/helper/functions.sh

# No kill switch to verify without a VPN (fail-secure: only exactly "no" skips).
if [[ $VPN_ENABLED == "no" ]]; then
	sleep infinity
fi

echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] Firewall (kill switch) check running every ${FIREWALL_CHECK_INTERVAL}s."

while :; do
	# The kill switch is down if its nftables rules are gone or if the internet can be
	# reached over the docker interface (bypassing the VPN).
	if ! firewall_rules_intact || firewall_bypassed; then
		echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] Firewall is down! Killing qBittorrent!"
		stop_container
	fi

	sleep "${FIREWALL_CHECK_INTERVAL}"
done
