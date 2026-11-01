#!/bin/bash

# shellcheck disable=SC1091
source /scripts/helper/functions.sh

##########
# Build info

echo "Image build from commit $(cat /etc/image-source-commit) on $(cat /etc/image-build-date)"
echo "--------------------"

##########
# Host network mode?

# Check for presence of network interface docker0
check_network=$(ifconfig | grep docker0 || true)

# If network interface docker0 is present then we are running in host mode and thus must exit
if [[ -n "${check_network}" ]]; then
	log_error "Network type detected as 'Host', this will cause major issues, please stop the container and switch back to 'Bridge' mode"
	stop_container
fi

##########
# Deprecation warnings

if [[ -n "${LEGACY_IPTABLES}" ]]; then
	log_warn "LEGACY_IPTABLES is no longer supported and is ignored. The firewall is always set up with nftables"
fi

##########
# WEBUI_ALLOWED_NETWORKS

if [[ -n "${WEBUI_ALLOWED_NETWORKS}" ]]; then
    log_info "WEBUI_ALLOWED_NETWORKS is defined as $WEBUI_ALLOWED_NETWORKS"
fi

#########
# Health and firewall check

DEFAULT_FIREWALL_CHECK_HOST="8.8.8.8"
DEFAULT_FIREWALL_CHECK_INTERVAL=5
DEFAULT_HEALTH_CHECK_HOST="1.1.1.1"
DEFAULT_HEALTH_CHECK_INTERVAL=5
DEFAULT_HEALTH_CHECK_TIMEOUT=15

if [[ -z "${HEALTH_CHECK_HOST}" ]]; then
    log_info "HEALTH_CHECK_HOST is not set. Using default host ${DEFAULT_HEALTH_CHECK_HOST}"
    HEALTH_CHECK_HOST=${DEFAULT_HEALTH_CHECK_HOST}
fi

if [[ -z "${HEALTH_CHECK_INTERVAL}" ]]; then
    log_info "HEALTH_CHECK_INTERVAL is not set. Using default interval of ${DEFAULT_HEALTH_CHECK_INTERVAL}s"
    HEALTH_CHECK_INTERVAL=${DEFAULT_HEALTH_CHECK_INTERVAL}
fi

if [[ -z "${HEALTH_CHECK_TIMEOUT}" ]]; then
    log_info "HEALTH_CHECK_TIMEOUT is not set. Using default interval of ${DEFAULT_HEALTH_CHECK_TIMEOUT}s"
    HEALTH_CHECK_TIMEOUT=${DEFAULT_HEALTH_CHECK_TIMEOUT}
fi

if [[ -z "${FIREWALL_CHECK_HOST}" ]]; then
	log_info "FIREWALL_CHECK_HOST is not set. Using default host ${DEFAULT_FIREWALL_CHECK_HOST}"
	FIREWALL_CHECK_HOST=${DEFAULT_FIREWALL_CHECK_HOST}
fi

if [[ -z "${FIREWALL_CHECK_INTERVAL}" ]]; then
	log_info "FIREWALL_CHECK_INTERVAL is not set. Using default interval of ${DEFAULT_FIREWALL_CHECK_INTERVAL}s"
	FIREWALL_CHECK_INTERVAL=${DEFAULT_FIREWALL_CHECK_INTERVAL}
fi

##########
# Network environment

# Identify docker bridge interface name (probably eth0)
DOCKER_INTERFACE="$(netstat -ie | grep -vE "lo" | sed -n '1!p' | grep -o -m 1 -P '^[\w]+')"
log_debug "Docker interface defined as ${DOCKER_INTERFACE}"

# Identify IPv4 address of docker bridge interface
docker_ipv4_cidr="$(ip -4 addr show dev "${DOCKER_INTERFACE}" | grep -o -m 1 -P '(?<=inet\s)\d+(\.\d+){3}\/\d+')"

# Identify link-local IPv6 address of docker bridge interface
docker_ipv6_ula_cidr="$(ip -6 addr show dev "${DOCKER_INTERFACE}" | grep -o -m 1 -P '(?<=inet6\s)fd[0-9a-f:]+\/[0-9]+')"


# IPv4
if [ -n "$docker_ipv4_cidr" ]; then
	# Get address without mask
	docker_ipv4="$(grep -o -m 1 -P '^[^\/]+' <<< "${docker_ipv4_cidr}")"
	log_debug "Docker IPv4 address defined as ${docker_ipv4}"

	# Calculate CIDR network notation
	DOCKER_IPV4_NETWORK_CIDR=$(ipcalc "${docker_ipv4_cidr}" | grep -o -m 1 -P "(?<=Network:)\s+[^\s]+" | sed -e 's/\s//g')
	log_debug "Docker IPv4 network defined as ${DOCKER_IPV4_NETWORK_CIDR}"

	# Get default gateway
	DEFAULT_IPV4_GATEWAY=$(ip -4 route list 0/0 | cut -d ' ' -f 3 | head -n 1)
	log_debug "Default IPv4 gateway defined as ${DEFAULT_IPV4_GATEWAY}"
fi

# IPv6
if [ -n "$docker_ipv6_ula_cidr" ]; then
	# Get address without mask
	docker_ipv6_ula="$(grep -o -m 1 -P '^[^\/]+' <<< "${docker_ipv6_ula_cidr}")"
	log_debug "Docker unique-local IPv6 address defined as ${docker_ipv6_ula}"

	# Calculate CIDR network notation
	DOCKER_IPV6_ULA_NETWORK_CIDR=$(ipcalc "${docker_ipv6_ula_cidr}" | grep -o -m 1 -P "(?<=Network:)\s+[^\s]+" | sed -e 's/\s//g')
	log_debug "Docker IPv6 network defined as ${DOCKER_IPV6_ULA_NETWORK_CIDR}"

	# Get default gateway
	DEFAULT_IPV6_GATEWAY=$(ip -6 route list ::0/0 | cut -d ' ' -f 3 | head -n 1)
	log_debug "Default IPv6 gateway defined as ${DEFAULT_IPV6_GATEWAY}"
fi

##########
# Reverse path filtering compatibility
# Required for wg-quick and WebUI PBR

if \
	# Check if reverse path filtering is set to 1 (strict)
	( \
		[ "$(sysctl net.ipv4.conf.all.rp_filter)" == "net.ipv4.conf.all.rp_filter = 1" ] || \
		[ "$(sysctl net.ipv4.conf.$DOCKER_INTERFACE.rp_filter)" == "net.ipv4.conf.$DOCKER_INTERFACE.rp_filter = 1" ] \
	) && \
	# Check if src_valid_mark is disabled
	( \
		[ "$(sysctl net.ipv4.conf.all.src_valid_mark)" != "net.ipv4.conf.all.src_valid_mark = 1" ] && \
		[ "$(sysctl net.ipv4.conf.$DOCKER_INTERFACE.src_valid_mark)" != "net.ipv4.conf.$DOCKER_INTERFACE.src_valid_mark = 1" ] \
	) && \
	# Try to enable src_valid_mark
	! (sysctl -q net.ipv4.conf.$DOCKER_INTERFACE.src_valid_mark=1 >/dev/null 2>&1)
then
	log_error "rp_filter is set to 1 (strict) and src_valid_mark is set to 0 and could not be enabled"
	stop_container
fi

##########
# PUID/PGID

if [[ -z "${PUID}" ]]; then
	log_info "PUID not defined. Defaulting to 1000"
	export PUID="1000"
else
	log_info "PUID defined as $PUID"
fi
if [[ -z "${PGID}" ]]; then
	log_info "PGID not defined. Defaulting to 1000"
	export PGID="1000"
else
	log_info "PGID defined as $PGID"
fi

if [[ ! "${PUID}" =~ ^[0-9]+$ ]] || [[ ! "${PGID}" =~ ^[0-9]+$ ]]; then
	log_error "PUID and PGID must be numeric IDs, got PUID='${PUID}' PGID='${PGID}'"
	stop_container
fi

# qBittorrent runs as the numeric PUID:PGID (see service-scripts/qbittorrent.sh). The 'qbittorrent' account only gives
# those IDs a name (ls, ps). An existing account with UID PUID is reused, otherwise 'qbittorrent' is (re)created.
qbt_user="$(getent passwd "${PUID}" | cut -d: -f1)"
if [[ -n "${qbt_user}" ]] && [[ "$(id -g "${qbt_user}")" == "${PGID}" ]]; then
	log_debug "User '${qbt_user}' with UID ${PUID} and GID ${PGID} already exists, nothing to do."
elif [[ -n "${qbt_user}" ]] && [[ "${qbt_user}" != "qbittorrent" ]]; then
	log_info "UID ${PUID} belongs to the existing account '${qbt_user}' (primary GID $(id -g "${qbt_user}")). qBittorrent still runs as ${PUID}:${PGID}"
else
	log_debug "Creating user 'qbittorrent' with UID ${PUID} and GID ${PGID}"
	# Drop a stale 'qbittorrent' account (other UID/GID from a previous boot); BusyBox deluser also removes its same-named group
	if getent passwd qbittorrent > /dev/null; then
		deluser qbittorrent > /dev/null 2>&1
	fi
	# Reuse the group that owns GID PGID (e.g. 'users' for 100), otherwise create 'qbittorrent' with that GID
	qbt_group="$(getent group "${PGID}" | cut -d: -f1)"
	if [[ -z "${qbt_group}" ]]; then
		if getent group qbittorrent > /dev/null; then
			delgroup qbittorrent > /dev/null 2>&1
		fi
		if addgroup -g "${PGID}" qbittorrent; then
			qbt_group="qbittorrent"
		fi
	fi
	if [[ -z "${qbt_group}" ]] || ! adduser -D -u "${PUID}" -G "${qbt_group}" qbittorrent; then
		log_warn "Could not create user 'qbittorrent' with UID ${PUID} and GID ${PGID}. qBittorrent still runs as ${PUID}:${PGID}, but files will show numeric owners"
	fi
fi

##########
# VPN

VPN_ENABLED=$(echo "${VPN_ENABLED,,}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
export VPN_ENABLED

if [[ -n "${VPN_ENABLED}" ]]; then
	log_info "VPN_ENABLED defined as '${VPN_ENABLED}'"
else
	log_info "VPN_ENABLED not defined (via -e VPN_ENABLED), defaulting to 'yes'"
fi

if [[ $VPN_ENABLED != "no" ]]; then
	export VPN_ENABLED="yes"
fi

if [[ $VPN_ENABLED != "no" ]]; then
    # Check if VPN_TYPE is set.
	if [[ -z "${VPN_TYPE}" ]]; then
		log_warn "VPN_TYPE not set, defaulting to Wireguard."
		export VPN_TYPE="wireguard"
    elif [[ "${VPN_TYPE}" != "openvpn" && "${VPN_TYPE}" != "wireguard" ]]; then
        log_warn "VPN_TYPE not set, as 'wireguard' or 'openvpn', defaulting to Wireguard."
		export VPN_TYPE="wireguard"
	else
		log_info "VPN_TYPE defined as '${VPN_TYPE}'"
	fi
elif [[ $VPN_ENABLED == "no" ]]; then
	BIRed=$'\033[1;91m'
	On_IGreen=$'\033[0;102m'
	COLOR_RESET=$'\033[0m'
	log_warn "${On_IGreen}${BIRed}You have set the VPN to disabled, your connection will NOT be secure.${COLOR_RESET}"
fi

##########
# Save environment variables

CONT_INIT_ENV="/var/run/s6/container_environment"
mkdir -p $CONT_INIT_ENV
export_vars=(
	"DOCKER_INTERFACE" 
	"DOCKER_IPV4_NETWORK_CIDR" 
	"DOCKER_IPV6_ULA_NETWORK_CIDR" 
	"DEFAULT_IPV4_GATEWAY" 
	"DEFAULT_IPV6_GATEWAY" 
	"PUID" 
	"PGID" 
	"VPN_TYPE" 
	"FIREWALL_CHECK_HOST" 
	"FIREWALL_CHECK_INTERVAL" 
	"HEALTH_CHECK_HOST" 
	"HEALTH_CHECK_INTERVAL" 
	"HEALTH_CHECK_TIMEOUT"
)

for name in "${export_vars[@]}"; do
	echo -n "${!name}" > "$CONT_INIT_ENV/$name"
done
