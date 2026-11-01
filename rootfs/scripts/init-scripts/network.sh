#!/bin/bash

set -euo pipefail

# shellcheck disable=SC1091
source /scripts/helper/functions.sh
##########
# Skip - Only needed if VPN is enabled

if [[ "${VPN_ENABLED:-}" == "no" ]]; then
    exit 0
fi

##########
# Error handling
# Any failing command below stops the container instead of leaving a half-configured network behind

# Log an error and stop the container. errexit is switched off first so stop_container always runs to completion
fail() {
	set +e
	log_error "$1"
	log_error "Network setup failed, stopping the container to prevent leaks"
	stop_container
}

on_error() {
	fail "network.sh failed at line $1 (exit code $?): $2"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

##########
# Constants

webui_port=8080
webui_fwmark=8080
webui_ctmark=9090
ruleset_file="/run/qbt-firewall.nft"

##########
# Validate the values that end up in firewall rules

if [[ ! "${VPN_PROTOCOL:-}" =~ ^(tcp|udp)$ ]]; then
	fail "VPN_PROTOCOL must be 'tcp' or 'udp', got '${VPN_PROTOCOL:-}'"
fi

is_port() {
	[[ "$1" =~ ^[0-9]{1,5}$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

if ! is_port "${VPN_PORT:-}"; then
	fail "VPN_PORT must be a port number, got '${VPN_PORT:-}'"
fi

if [[ -z "${VPN_DEVICE_TYPE:-}" || -z "${DOCKER_INTERFACE:-}" ]]; then
	fail "VPN_DEVICE_TYPE ('${VPN_DEVICE_TYPE:-}') and DOCKER_INTERFACE ('${DOCKER_INTERFACE:-}') must be set"
fi

##########
# Route WebUI traffic over "$DEFAULT_IPV4_GATEWAY"

mkdir -p /etc/iproute2/
echo "${webui_fwmark} webui" >> /etc/iproute2/rt_tables
if [[ -n "${DEFAULT_IPV4_GATEWAY:-}" ]]; then
	# Default
	ip rule add fwmark "${webui_fwmark}" table webui
	ip route add default via "${DEFAULT_IPV4_GATEWAY}" table webui
	# Look for local networks first
	ip rule add fwmark "${webui_fwmark}" table main suppress_prefixlength 1
fi
if [[ -n "${DEFAULT_IPV6_GATEWAY:-}" ]]; then
	# Default
	ip -6 rule add fwmark "${webui_fwmark}" table webui
	ip -6 route add default via "${DEFAULT_IPV6_GATEWAY}" table webui
	# Look for local networks first
	ip -6 rule add fwmark "${webui_fwmark}" table main suppress_prefixlength 1
fi

##########
# VPN_REMOTE IP

VPN_REMOTE_IPv4_ADDRESSES=()
VPN_REMOTE_IPv6_ADDRESSES=()
VPN_REMOTE_IP=""

# VPN_REMOTE is already an IPv4 address
if (ipcalc -c -4 "${VPN_REMOTE:-}" > /dev/null 2>&1); then
	VPN_REMOTE_IPv4_ADDRESSES+=("${VPN_REMOTE}")
# VPN_REMOTE is already an IPv6 address
elif (ipcalc -c -6 "${VPN_REMOTE:-}" > /dev/null 2>&1); then
	VPN_REMOTE_IPv6_ADDRESSES+=("${VPN_REMOTE}")
# VPN_REMOTE is a hostname
else
	if [[ "${VPN_TYPE:-}" == "openvpn" ]]; then
		while ! VPN_REMOTE_IP=$(grep -o -m 1 -P 'Peer Connection Initiated with [^\d]+\K(\d+(\.\d+){3})(?=:\d+)' < /var/log/openvpn.log); do sleep 0.1; done
	else
		VPN_REMOTE_IP="$(wg show | grep -o -m 1 -P '((?<=endpoint:\s\[)[0-9a-f:]+(?=\]:\d+$))|((?<=endpoint:\s)[0-9.]+(?=:\d+$))' || true)"
	fi

	if (ipcalc -c -4 "${VPN_REMOTE_IP}" > /dev/null 2>&1); then
		VPN_REMOTE_IPv4_ADDRESSES+=("${VPN_REMOTE_IP}")
	elif (ipcalc -c -6 "${VPN_REMOTE_IP}" > /dev/null 2>&1); then
		VPN_REMOTE_IPv6_ADDRESSES+=("${VPN_REMOTE_IP}")
	else
		fail "neither ${VPN_REMOTE:-} (VPN_REMOTE) nor \"${VPN_REMOTE_IP}\" (obtained from the VPN client) is a valid IP"
	fi
fi

log_debug "VPN_REMOTE_IPv4_ADDRESSES defined as (${VPN_REMOTE_IPv4_ADDRESSES[*]})"
log_debug "VPN_REMOTE_IPv6_ADDRESSES defined as (${VPN_REMOTE_IPv6_ADDRESSES[*]})"

##########
# Optional rules (collected first, emitted into the ruleset below)

input_rules=()
output_rules=()

# Input to WebUI
webui_allowed_ipv4=()
webui_allowed_ipv6=()
if [[ -z "${WEBUI_ALLOWED_NETWORKS:-}" ]]; then
	input_rules+=("tcp dport ${webui_port} accept comment \"Accept input to the qBt WebUI\"")
else
	# Split comma separated string into list from WEBUI_ALLOWED_NETWORKS env variable
	IFS=',' read -ra allowed_networks_array <<< "${WEBUI_ALLOWED_NETWORKS}"

	for address in "${allowed_networks_array[@]}"; do
		# Remove whitespaces (for ipcalc)
		address="${address//[[:space:]]/}"

		if (ipcalc -c -4 "${address}" > /dev/null 2>&1); then
			webui_allowed_ipv4+=("${address}")
		elif (ipcalc -c -6 "${address}" > /dev/null 2>&1); then
			webui_allowed_ipv6+=("${address}")
		else
			fail "'${address}' in WEBUI_ALLOWED_NETWORKS is not a valid IPv4/IPv6 address or network"
		fi
	done

	input_rules+=("tcp dport ${webui_port} ip saddr @webui_allowed_networks_ipv4 counter accept comment \"Accept input to the qBt WebUI (IPv4)\"")
	input_rules+=("tcp dport ${webui_port} ip6 saddr @webui_allowed_networks_ipv6 counter accept comment \"Accept input to the qBt WebUI (IPv6)\"")
fi

##########
# Generate the nftables ruleset
# The whole file is loaded in one transaction: either every rule is applied or none are

# Print a named set, optionally with elements. Usage: nft_set <name> <type> <flags or ""> [element...]
nft_set() {
	local name="$1" type="$2" flags="$3" elements
	shift 3
	echo "	set ${name} {"
	echo "		type ${type}"
	if [[ -n "${flags}" ]]; then
		echo "		flags ${flags}"
	fi
	if [[ $# -gt 0 ]]; then
		printf -v elements '%s, ' "$@"
		echo "		elements = { ${elements%, } }"
	fi
	echo "	}"
}

# Print rules, one per line, indented for a chain body
nft_rules() {
	local rule
	for rule in "$@"; do
		echo "		${rule}"
	done
}

{
cat <<EOF
# Generated by /scripts/init-scripts/network.sh on $(date +'%Y-%m-%d %H:%M:%S')
# Loaded atomically with 'nft -f ${ruleset_file}'

# Mark packets belonging to a WebUI connection (for policy routing and the firewall)
table inet qbt-mark {
	chain prerouting {
		type filter hook prerouting priority -150;
		tcp dport ${webui_port} ct state new ct mark set ${webui_ctmark} counter comment "Track new WebUI connections"
		tcp dport ${webui_port} meta mark set ${webui_fwmark} counter comment "Mark packets to pass rp_filter reverse path route lookup"
	}

	chain output {
		type route hook output priority -150;
		ct mark ${webui_ctmark} meta mark set ${webui_fwmark} counter comment "Add mark to outgoing packets belonging to a WebUI connection"
	}
}

# Kill switch: only the VPN tunnel, the VPN server, loopback, the WebUI and ICMP control traffic are allowed
table inet qbt-firewall {
EOF

nft_set vpn_ipv4 ipv4_addr "" "${VPN_REMOTE_IPv4_ADDRESSES[@]}"
nft_set vpn_ipv6 ipv6_addr "" "${VPN_REMOTE_IPv6_ADDRESSES[@]}"
if [[ -n "${WEBUI_ALLOWED_NETWORKS:-}" ]]; then
	nft_set webui_allowed_networks_ipv4 ipv4_addr interval "${webui_allowed_ipv4[@]}"
	nft_set webui_allowed_networks_ipv6 ipv6_addr interval "${webui_allowed_ipv6[@]}"
fi

cat <<EOF

	chain input {
		type filter hook input priority 0; policy drop;
		iifname "${VPN_DEVICE_TYPE}" accept comment "Accept input from VPN tunnel"
		${VPN_PROTOCOL} sport ${VPN_PORT} ip saddr @vpn_ipv4 accept comment "Accept input from VPN server (IPv4)"
		${VPN_PROTOCOL} sport ${VPN_PORT} ip6 saddr @vpn_ipv6 accept comment "Accept input from VPN server (IPv6)"
		iifname "lo" accept comment "Accept input from internal loopback"
		icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } accept comment "Basic ICMPv6 NDP"
		icmpv6 type { destination-unreachable, packet-too-big, time-exceeded } accept comment "Basic ICMPv6 errors (optional)"
		icmp type { destination-unreachable, time-exceeded } accept comment "Basic ICMP errors (optional)"
		icmp type echo-request accept comment "Respond to IPv4 pings (optional)"
		icmpv6 type echo-request accept comment "Respond to IPv6 pings (optional)"
EOF
nft_rules "${input_rules[@]}"
cat <<EOF
	}

	chain output {
		type filter hook postrouting priority 0; policy drop;
		oifname "${VPN_DEVICE_TYPE}" accept comment "Accept output to VPN tunnel"
		${VPN_PROTOCOL} dport ${VPN_PORT} ip daddr @vpn_ipv4 accept comment "Accept output to VPN server (IPv4)"
		${VPN_PROTOCOL} dport ${VPN_PORT} ip6 daddr @vpn_ipv6 accept comment "Accept output to VPN server (IPv6)"
		tcp sport ${webui_port} meta mark ${webui_fwmark} counter accept comment "Accept outgoing packets belonging to a WebUI connection"
		oifname "lo" accept comment "Accept output to internal loopback"
		icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } accept comment "Basic ICMPv6 NDP"
		icmpv6 type { destination-unreachable, packet-too-big, time-exceeded } accept comment "ICMPv6 errors (optional)"
		icmp type { destination-unreachable, time-exceeded } accept comment "ICMP errors (optional)"
		icmp type echo-reply accept comment "Respond to IPv4 pings (optional)"
		icmpv6 type echo-reply accept comment "Respond to IPv6 pings (optional)"
EOF
nft_rules "${output_rules[@]}"
cat <<EOF
	}
}
EOF
} > "${ruleset_file}"

##########
# Load the ruleset

log_info "Loading nftables ruleset from ${ruleset_file}"
if ! nft -f "${ruleset_file}"; then
	fail "Failed to load the nftables ruleset, no firewall rules were applied. Check the nft errors above and that the host kernel provides nf_tables (see docs/troubleshooting/common-issues.md)"
fi

if [[ "${DEBUG:-}" == "yes" ]]; then
	log_debug "'main' routing table defined as follows..."
	echo "--------------------"
	ip route show table main
	echo "--------------------"

	log_debug "ip rules defined as follows..."
	echo "--------------------"
	ip rule
	echo "--------------------"

	log_debug "nft ruleset defined as follows..."
	echo "--------------------"
	nft list ruleset
	echo "--------------------"

	# Diagnostics only (shared helper, not written for set -u), a failure here must not stop the container
	( set +u; test_connection ) || true
fi

##########
# Save environment variables

CONT_INIT_ENV="/var/run/s6/container_environment"
mkdir -p "${CONT_INIT_ENV}"
export_vars=("DOCKER_INTERFACE")

for name in "${export_vars[@]}"; do
	echo -n "${!name}" > "${CONT_INIT_ENV}/${name}"
done
