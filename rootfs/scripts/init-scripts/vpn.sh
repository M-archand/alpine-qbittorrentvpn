#!/bin/bash

# shellcheck disable=SC1091
source /scripts/helper/functions.sh
##########
# Skip if VPN is disabled

if [[ $VPN_ENABLED == "no" ]]; then
    exit 0
fi

##########
# Check for config file

# Create config dir (if it doesn't exist)
mkdir -p "/config/${VPN_TYPE}"

# Wildcard search for openvpn config files and store results in array
if [[ "${VPN_TYPE}" == "openvpn" ]]; then
    mapfile -t VPN_CONFIGS < <( find /config/openvpn -maxdepth 1 -name "*.ovpn" -print )
else
    mapfile -t VPN_CONFIGS < <( find /config/wireguard -maxdepth 1 -name "*.conf" -print )
fi

# Choose random config
VPN_CONFIG="${VPN_CONFIGS[$RANDOM % ${#VPN_CONFIGS[@]}]}"

# Get the VPN_CONFIG name without the path and extension
VPN_CONFIG_BASENAME="${VPN_CONFIG##*/}"
VPN_CONFIG_NAME="${VPN_CONFIG_BASENAME%.*}"

log_info "Chosen VPN config: '${VPN_CONFIG_BASENAME}'"

export VPN_CONFIG
export VPN_CONFIG_NAME

# If VPN config file not found in /config/openvpn or /config/wireguard then exit
if [[ -z ${VPN_CONFIG} ]]; then
    if [[ ${VPN_TYPE} == "openvpn" ]]; then
        fail_init "No OpenVPN config file found in /config/openvpn/. Please download one from your VPN provider and restart this container. Make sure the file extension is '.ovpn'"
    else
        fail_init "No WireGuard config file found in /config/wireguard/. Please download one from your VPN provider and restart this container. Make sure the file extension is '.conf'"
    fi
fi

##########
# Working copy
# The user's file is never modified: it may be read-only or a single-file bind mount, and every edit to it would be
# permanent. Everything below reads and edits a private copy under /run; the basename is kept because wg-quick derives
# the interface name from it. Relative paths inside an .ovpn still resolve, OpenVPN is started from /config/openvpn.

VPN_CONFIG_SOURCE="${VPN_CONFIG}"
VPN_CONFIG="/run/${VPN_TYPE}/${VPN_CONFIG_BASENAME}"
if ! (umask 077 && mkdir -p "/run/${VPN_TYPE}" && cp "${VPN_CONFIG_SOURCE}" "${VPN_CONFIG}"); then
    fail_init "Could not copy ${VPN_CONFIG_SOURCE} to ${VPN_CONFIG}"
fi

# Convert CRLF (windows) to LF (unix)
dos2unix -q "${VPN_CONFIG}"

##########
# OpenVPN credentials

if [[ "${VPN_TYPE}" == "openvpn" ]]; then
    # Remove auth-user-pass line(s) so credentials come only from the file/CLI, never an interactive prompt
    sed -i -E '/^[[:space:]]*auth-user-pass([[:space:]]|$)/d' "${VPN_CONFIG}"
    # Use credentials from credentials file if it exists
    if [[ -f /config/openvpn/"${VPN_CONFIG_NAME}"_credentials.conf ]]; then
        log_info "Using credentials from /config/openvpn/${VPN_CONFIG_NAME}_credentials.conf"
    # Else use credentials from env vars if set and non empty
    elif [[ -n "${VPN_USERNAME}" ]] && [[ -n "${VPN_PASSWORD}" ]]; then
        log_info "Copying credentials from env vars to /config/openvpn/${VPN_CONFIG_NAME}_credentials.conf"
        echo "${VPN_USERNAME}" > /config/openvpn/"${VPN_CONFIG_NAME}"_credentials.conf
        echo "${VPN_PASSWORD}" >> /config/openvpn/"${VPN_CONFIG_NAME}"_credentials.conf
    # Else if both username and password are set but empty, assume custom authentication method
    elif [[ -z "${VPN_USERNAME-unset}" ]] && [[ -z "${VPN_PASSWORD-unset}" ]]; then
        log_info "Credentials explicitly set to empty string"
    # Else if a credentials.conf file exists, assume it is valid for all VPN configs
    elif [[ -f /config/openvpn/credentials.conf ]]; then
        log_info "Copying credentials from /config/openvpn/credentials.conf to /config/openvpn/${VPN_CONFIG_NAME}_credentials.conf"
        cp /config/openvpn/credentials.conf /config/openvpn/"${VPN_CONFIG_NAME}"_credentials.conf
    else
        fail_init "No credentials set and didn't find a credential config file."
    fi
fi

##########
# Read VPN config

# Parse values from the ovpn or conf file
if [[ "${VPN_TYPE}" == "openvpn" ]]; then
    export vpn_remote_line=$( (grep -o -m 1 -P '(?<=^remote\s)[^\n\r]+' | sed -e 's~^[ \t]*~~;s~[ \t]*$~~') < "${VPN_CONFIG}")
else
    export vpn_remote_line=$( (grep -o -m 1 -P '(?<=^Endpoint)(\s{0,})[^\n\r]+' | sed -e 's~^[=\ ]*~~') < "${VPN_CONFIG}")
fi

if [[ -z "${vpn_remote_line}" ]]; then
    log_error "VPN configuration file ${VPN_CONFIG_SOURCE} does not contain 'remote' line:"
    cat "${VPN_CONFIG}"
    fail_init "VPN configuration file ${VPN_CONFIG_SOURCE} does not contain a 'remote' line"
else
    log_debug "VPN remote line defined as '${vpn_remote_line}'"
fi

if [[ "${VPN_TYPE}" == "openvpn" ]]; then
    export VPN_REMOTE=$(echo "${vpn_remote_line}" | grep -o -m 1 -P '^[^\s\r\n]+' | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
else
    export VPN_REMOTE=$(echo "${vpn_remote_line}" | grep -o -m 1 -P '((?<=\[)[a-f0-9:]+(?=\]:\d+\s*$))|([^\s\[\]]+)(?=:\d+\s*$)')
fi

if [[ -n "${VPN_REMOTE}" ]]; then
    log_info "VPN_REMOTE defined as '${VPN_REMOTE}'"
else
    fail_init "VPN_REMOTE not found in ${VPN_CONFIG_SOURCE}"
fi

if [[ "${VPN_TYPE}" == "openvpn" ]]; then
    export VPN_PORT=$(echo "${vpn_remote_line}" | grep -o -m 1 -P '^[^#;]*\s\K\d{2,5}(?=.*$)')
else
    export VPN_PORT=$(echo "${vpn_remote_line}" | grep -o -m 1 -P '^[^#]*:\K\d{2,5}(?=.*$)')
fi

if [[ -n "${VPN_PORT}" ]]; then
    log_info "VPN_PORT defined as '${VPN_PORT}'"
else
    fail_init "VPN_PORT not found in ${VPN_CONFIG_SOURCE}"
fi

if [[ "${VPN_TYPE}" == "openvpn" ]]; then
    export VPN_PROTOCOL=$( (grep -o -m 1 -P '(?<=^proto\s)[^\r\n]+' | sed -e 's~^[ \t]*~~;s~[ \t]*$~~') < "${VPN_CONFIG}")
    if [[ -n "${VPN_PROTOCOL}" ]]; then
        log_info "VPN_PROTOCOL defined as '${VPN_PROTOCOL}'"
    else
        export VPN_PROTOCOL=$(echo "${vpn_remote_line}" | grep -o -m 1 -P 'udp|tcp-client|tcp$' | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
        if [[ -n "${VPN_PROTOCOL}" ]]; then
            log_info "VPN_PROTOCOL defined as '${VPN_PROTOCOL}'"
        else
            log_warn "VPN_PROTOCOL not found in ${VPN_CONFIG_SOURCE}, assuming udp"
            export VPN_PROTOCOL="udp"
        fi
    fi
    # Required for use in firewall rules
    if [[ "${VPN_PROTOCOL}" == "tcp-client" ]]; then
        export VPN_PROTOCOL="tcp"
    fi
else
    export VPN_PROTOCOL="udp"
    log_info "VPN_PROTOCOL set as '${VPN_PROTOCOL}'"
fi


if [[ "${VPN_TYPE}" == "openvpn" ]]; then
    VPN_DEVICE_TYPE=$( grep -o -m 1 -P '(?<=^dev\s)[^\s]+' < "${VPN_CONFIG}")

    if [[ -z "${VPN_DEVICE_TYPE}" ]]; then
        fail_init "VPN_DEVICE_TYPE not found in ${VPN_CONFIG_SOURCE}"
    fi

    # If device name has no number, append 0
    if [[ ! "${VPN_DEVICE_TYPE}" =~ ^.*[0-9]$ ]]; then
        export VPN_DEVICE_TYPE="${VPN_DEVICE_TYPE}0"
    fi
    
    log_info "VPN_DEVICE_TYPE defined as '${VPN_DEVICE_TYPE}'"
else
    export VPN_DEVICE_TYPE="$VPN_CONFIG_NAME"
    log_info "VPN_DEVICE_TYPE set as '${VPN_DEVICE_TYPE}'"
fi

##########
# Unprivileged mode
# rp_filter compatibility is already checked in environment.sh

if [[ "${VPN_TYPE}" == "wireguard" ]]; then
    # Strip wg-quick's src_valid_mark sysctl (fails in unprivileged containers), match the command, not the full line
    wg_quick_bin="$(command -v wg-quick-custom)"
    sed -i -E '/cmd sysctl -q net\.ipv4\.conf\.all\.src_valid_mark=1/d' "$wg_quick_bin"
    if grep -q 'src_valid_mark=1' "$wg_quick_bin"; then
        log_warn "Could not strip src_valid_mark sysctl from wg-quick, WireGuard may fail in unprivileged containers"
    fi
fi

##########
# DNS: let openresolv take over resolv.conf (kept as interface "control") so wg-quick/openvpn-dns.sh can rewrite it; openresolv >= 3.17 refuses files it did not create ("signature mismatch")

resolvconf -a control < /etc/resolv.conf 2>/dev/null || true
if ! resolvconf -u 2>/dev/null; then
    log_warn "openresolv could not take over /etc/resolv.conf, DNS servers provided by the VPN may fail to apply"
fi

##########
# Start VPN

if [[ "$DEBUG" == "yes" ]]; then
    test_connection
fi

# A failing command while the tunnel comes up parks the container (same contract as every other fatal error, see
# fail_init in functions.sh). qBittorrent has not started at this point, so nothing can leak.
on_error() {
    fail_init "vpn.sh failed at line $1 (exit code $?): $2"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
set -e

if [[ $VPN_ENABLED != "no" ]]; then
    # Manually create tun device
    # For OpenVPN this is always necessary when in unprivileged mode
    # For Wireguard this is necessary on older kernel versions when in unprivileged mode
    mkdir -p /dev/net
    if [ ! -c /dev/net/tun ]; then
        mknod /dev/net/tun c 10 200
    fi
    
	if [[ "${VPN_TYPE}" == "openvpn" ]]; then
        log_info "Starting OpenVPN..."
        echo "--------------------"

        # Delete if file persisted between reboots
        if [ -f /tmp/openvpn_startup_finished ]; then rm /tmp/openvpn_startup_finished; fi

        # Relative paths in the .ovpn (ca, cert, key, ...) resolve against the user's directory, not the copy's
        pushd /config/openvpn/ > /dev/null

        # Build the OpenVPN command line
        openvpn_args=(
            --config "${VPN_CONFIG}"
            --script-security 2
            --route-up /scripts/helper/resume-after-connect.sh
        )

        # Use the credentials file if it exists and is not empty
        if [[ -s /config/openvpn/"${VPN_CONFIG_NAME}"_credentials.conf ]]; then
            openvpn_args+=(--auth-user-pass /config/openvpn/"${VPN_CONFIG_NAME}"_credentials.conf)
        fi

        # Apply the DNS servers pushed by the server
        openvpn_args+=(--up /scripts/helper/openvpn-dns.sh --down /scripts/helper/openvpn-dns.sh)

        # Ignore pushed IPv6 options if IPv6 is disabled
        if [ "$(cat /sys/module/ipv6/parameters/disable)" != "0" ]; then
            openvpn_args+=(
                --pull-filter ignore "route-ipv6"
                --pull-filter ignore "ifconfig-ipv6"
                --pull-filter ignore "tun-ipv6"
                --pull-filter ignore "redirect-gateway ipv6"
                --pull-filter ignore "dhcp-option DNS6"
            )
        fi

        log_debug "OpenVPN command: openvpn ${openvpn_args[*]}"

        openvpn "${openvpn_args[@]}" | tee /var/log/openvpn.log &

        # Revert to previous directory
        popd > /dev/null

        # Get OpenVPN PID
        openvpn_pid=$(pidof openvpn)
        log_debug "OpenVPN PID: $openvpn_pid"

        # Wait for startup
        while :; do
            # Process exited
            if ! kill -0 "$openvpn_pid" 2>/dev/null; then
                echo "--------------------"
                fail_init "Failed to start OpenVPN"
            # Startup was successfull
            elif [[ -f /tmp/openvpn_startup_finished ]]; then
                break
            fi
            sleep 0.1
        done
        echo "--------------------"

	else
		log_info "Starting WireGuard..."
		echo "--------------------"
		wg-quick-custom up "$VPN_CONFIG"
		echo "--------------------"
	fi
fi

set +e
trap - ERR

if [[ "$DEBUG" == "yes" ]]; then
    test_connection
fi

##########
# Save environment variables

export_contenv VPN_REMOTE VPN_PORT VPN_PROTOCOL VPN_DEVICE_TYPE VPN_CONFIG_NAME
