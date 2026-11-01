#!/bin/bash
# OpenVPN --route-up hook, runs once the tunnel is up and its routes are installed.
# 1. Record the VPN server address OpenVPN connected to (OPENVPN_REMOTE_IP_FILE, read by network.sh for the kill switch).
#    trusted_ip (IPv4) or trusted_ip6 (IPv6) is set by OpenVPN for its hooks.
# 2. Signal vpn.sh that startup finished. The address is written first, so it exists before init continues.
# shellcheck disable=SC2154

# shellcheck disable=SC1091
source /scripts/helper/functions.sh

printf '%s\n' "${trusted_ip6:-${trusted_ip:-}}" > "${OPENVPN_REMOTE_IP_FILE}"
touch /tmp/openvpn_startup_finished
