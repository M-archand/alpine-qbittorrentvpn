# shellcheck shell=bash

##########
# Logging
# Every line is "<timestamp> [LEVEL] message" so the container log can be grepped by level.
# log_debug prints only when DEBUG=yes and always returns 0, so it is safe under set -e.

_log() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "${level}" "$*"
}

log_info() { _log INFO "$@"; }
log_warn() { _log WARNING "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() {
    if [[ "${DEBUG:-}" == "yes" ]]; then
        _log DEBUG "$@"
    fi
}

##########
# Container environment
# Variables written here are visible to every later oneshot and longrun started through with-contenv.
# Arrays are written space separated.

CONT_INIT_ENV="/var/run/s6/container_environment"

# Usage: export_contenv VAR...
export_contenv() {
    local _contenv_name
    mkdir -p "${CONT_INIT_ENV}"
    for _contenv_name in "$@"; do
        # Fresh nameref per variable: assigning to a bound nameref would write through to the previous target
        local -n _contenv_ref="${_contenv_name}"
        printf '%s' "${_contenv_ref[*]:-}" > "${CONT_INIT_ENV}/${_contenv_name}"
        unset -n _contenv_ref
    done
}

test_connection () {
    # Resolve HEALTH_CHECK_HOST if domain
    if (ipcalc -c "$HEALTH_CHECK_HOST" > /dev/null 2>&1); then
        health_check_ip=$HEALTH_CHECK_HOST
    else
        health_check_ip="$(dig +short "$HEALTH_CHECK_HOST" | head -n 1)"
        log_debug "$HEALTH_CHECK_HOST resolved to $health_check_ip"
    fi
    
    log_debug "Route: $(ip r get "$health_check_ip" | head -n 1)"

    if (ping -c 1 "$health_check_ip" > /dev/null 2>&1); then
        log_debug "Ping to $health_check_ip succeeded"
    else
        log_debug "Ping to $health_check_ip failed"
    fi

    # Resolve VPN_REMOTE if domain
    if [[ -n "$VPN_REMOTE_IP" ]]; then
        vpn_remote_ip="$VPN_REMOTE_IP"
    elif (ipcalc -c "$VPN_REMOTE" > /dev/null 2>&1); then
        vpn_remote_ip=$VPN_REMOTE
    else
        vpn_remote_ip="$(dig +short "$VPN_REMOTE" | head -n 1)"
        log_debug "$VPN_REMOTE resolved to $vpn_remote_ip"
    fi

    if (ping -w 1 -c 1 -I "$DOCKER_INTERFACE" "$vpn_remote_ip" > /dev/null 2>&1); then
        log_debug "Ping to $vpn_remote_ip via $DOCKER_INTERFACE succeeded"
    else
        log_debug "Ping to $vpn_remote_ip via $DOCKER_INTERFACE failed"
    fi
}

# Kill switch intact? Both qbt-firewall chains must exist with policy drop (returns 1 and logs otherwise)
firewall_rules_intact() {
    local chain
    for chain in input output; do
        if ! nft list chain inet qbt-firewall "$chain" 2>/dev/null | grep -q 'policy drop;'; then
            log_error "nftables chain 'inet qbt-firewall $chain' with policy drop is missing"
            return 1
        fi
    done
}

# Kill switch bypassed? Probes HEALTH_CHECK_HOST and FIREWALL_CHECK_HOST over the docker interface with ICMP echo
# and a TCP connect to port 53, all bound to the interface and run in parallel. Returns 0 (and logs) if any
# probe gets through, so a host that drops ICMP cannot hide a TCP leak.
firewall_bypassed() {
    local host i rc connect_time bypassed=1
    local -a hosts=() ping_pids=() curl_pids=() curl_outputs=()

    for host in "$HEALTH_CHECK_HOST" "$FIREWALL_CHECK_HOST"; do
        hosts+=("$host")
        ping -w 1 -c 1 -I "$DOCKER_INTERFACE" "$host" > /dev/null 2>&1 &
        ping_pids+=($!)
        curl_outputs+=("$(mktemp)")
        # time_connect stays 0 unless the TCP handshake completed, whatever happens afterwards
        curl --interface "if!${DOCKER_INTERFACE}" --connect-timeout 2 --max-time 3 -s -o /dev/null -w '%{time_connect}' "http://${host}:53" > "${curl_outputs[-1]}" 2>/dev/null &
        curl_pids+=($!)
    done

    for i in "${!hosts[@]}"; do
        if wait "${ping_pids[$i]}"; then
            log_error "ICMP echo to ${hosts[$i]} over ${DOCKER_INTERFACE} succeeded"
            bypassed=0
        fi
        wait "${curl_pids[$i]}"
        rc=$?
        connect_time="$(cat "${curl_outputs[$i]}" 2>/dev/null)"
        rm -f "${curl_outputs[$i]}"
        if [[ "$rc" == "0" ]] || awk -v t="${connect_time:-0}" 'BEGIN { exit !(t + 0 > 0) }'; then
            log_error "TCP connection to ${hosts[$i]}:53 over ${DOCKER_INTERFACE} succeeded"
            bypassed=0
        fi
    done

    return "$bypassed"
}

##########
# Fatal errors
# One contract for every fatal condition: the container is parked, never exited. The reason goes to STOP_MARKER,
# qBittorrent does not run, and the container stays "running" so no restart policy loops it back into the same failure
# (or through the leak window again). The Docker HEALTHCHECK (/scripts/helper/healthcheck.sh) reports it unhealthy
# while the marker exists; init-environment removes the marker, so a restart gives a clean slate.
# Two entry points, neither returns:
#   fail_init        for oneshots (init-*): sleeps forever, so the init bundle never completes and no longrun starts
#   trip_kill_switch for longruns (firewall-check, qBittorrent pre-start check): downs qBittorrent and the check
#                    services, then exits the caller

STOP_MARKER="/run/qbt-stopped"

_park() {
    # errexit off so a caller running under it (network.sh, the tunnel start in vpn.sh) cannot bail out halfway through
    set +e
    local reason="${*:-see the container log}"
    log_error "${reason}"
    log_error "Container parked: qBittorrent is stopped and the health check reports unhealthy until the container is restarted"
    printf '%s\n' "${reason}" > "${STOP_MARKER}"
}

# Usage: fail_init reason
fail_init() {
    _park "$@"
    sleep infinity
}

# Usage: trip_kill_switch reason
# service-qbittorrent gets SIGKILL (every second it runs without the kill switch leaks), service-connectivity-check
# and service-firewall-check get SIGTERM; all three are wanted down, so s6 does not restart them, and
# service-connectivity-check/finish skips its halt while the marker exists. The caller's own service is only marked
# "do not restart" (s6-svc -O) instead of being signalled, so this function runs to the end whichever longrun calls it,
# and that service goes down with the exit below.
trip_kill_switch() {
    _park "$@"
    local svc
    for svc in service-qbittorrent service-connectivity-check service-firewall-check; do
        if [[ "$(s6-svstat -o pid "/run/service/${svc}" 2>/dev/null)" == "$$" ]]; then
            s6-svc -O "/run/service/${svc}" >/dev/null 2>&1
        elif [[ "${svc}" == "service-qbittorrent" ]]; then
            s6-svc -k -d "/run/service/${svc}" >/dev/null 2>&1
        else
            s6-svc -d "/run/service/${svc}" >/dev/null 2>&1
        fi
    done

    # Ensure no qbittorrent-nox survives the service kill.
    killall qbittorrent-nox >/dev/null 2>&1

    exit 0
}
