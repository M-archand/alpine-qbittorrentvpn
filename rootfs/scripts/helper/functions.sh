# shellcheck shell=bash

test_connection () {
    # Resolve HEALTH_CHECK_HOST if domain
    if (ipcalc -c "$HEALTH_CHECK_HOST" > /dev/null 2>&1); then
        health_check_ip=$HEALTH_CHECK_HOST
    else
        health_check_ip="$(dig +short "$HEALTH_CHECK_HOST" | head -n 1)"
        echo "$(date +'%Y-%m-%d %H:%M:%S') [DEBUG] $HEALTH_CHECK_HOST resolved to $health_check_ip"
    fi
    
    echo "$(date +'%Y-%m-%d %H:%M:%S') [DEBUG] Route: $(ip r get "$health_check_ip" | head -n 1)"

    if (ping -c 1 "$health_check_ip" > /dev/null 2>&1); then
        echo "$(date +'%Y-%m-%d %H:%M:%S') [DEBUG] Ping to $health_check_ip succeeded"
    else
        echo "$(date +'%Y-%m-%d %H:%M:%S') [DEBUG] Ping to $health_check_ip failed"
    fi

    # Resolve VPN_REMOTE if domain
    if [[ -n "$VPN_REMOTE_IP" ]]; then
        vpn_remote_ip="$VPN_REMOTE_IP"
    elif (ipcalc -c "$VPN_REMOTE" > /dev/null 2>&1); then
        vpn_remote_ip=$VPN_REMOTE
    else
        vpn_remote_ip="$(dig +short "$VPN_REMOTE" | head -n 1)"
        echo "$(date +'%Y-%m-%d %H:%M:%S') [DEBUG] $VPN_REMOTE resolved to $vpn_remote_ip"
    fi

    if (ping -w 1 -c 1 -I "$DOCKER_INTERFACE" "$vpn_remote_ip" > /dev/null 2>&1); then
        echo "$(date +'%Y-%m-%d %H:%M:%S') [DEBUG] Ping to $vpn_remote_ip via $DOCKER_INTERFACE succeeded"
    else
        echo "$(date +'%Y-%m-%d %H:%M:%S') [DEBUG] Ping to $vpn_remote_ip via $DOCKER_INTERFACE failed"
    fi
}

# Kill switch intact? Both qbt-firewall chains must exist with policy drop (returns 1 and logs otherwise)
firewall_rules_intact() {
    local chain
    for chain in input output; do
        if ! nft list chain inet qbt-firewall "$chain" 2>/dev/null | grep -q 'policy drop;'; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] nftables chain 'inet qbt-firewall $chain' with policy drop is missing"
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
            echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] ICMP echo to ${hosts[$i]} over ${DOCKER_INTERFACE} succeeded"
            bypassed=0
        fi
        wait "${curl_pids[$i]}"
        rc=$?
        connect_time="$(cat "${curl_outputs[$i]}" 2>/dev/null)"
        rm -f "${curl_outputs[$i]}"
        if [[ "$rc" == "0" ]] || awk -v t="${connect_time:-0}" 'BEGIN { exit !(t + 0 > 0) }'; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] TCP connection to ${hosts[$i]}:53 over ${DOCKER_INTERFACE} succeeded"
            bypassed=0
        fi
    done

    return "$bypassed"
}

stop_container() {
    # Kill-switch trip: stop fast and stay down (no restart) to prevent leaks.
    s6-svc -k -d /run/service/service-qbittorrent/ >/dev/null 2>&1
    s6-svc -k -d /run/service/service-firewall-check/ >/dev/null 2>&1
    s6-svc -k -d /run/service/service-connectivity-check/ >/dev/null 2>&1

    # Ensure no qbittorrent-nox survives the service kill.
    killall qbittorrent-nox >/dev/null 2>&1

    sleep infinity
}

print_exit_info () {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR INFO] 'ip addr show' output:"
	echo "--------------------"
	ip addr show
	echo "--------------------"
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR INFO] 'ip route show table main' output:"
	echo "--------------------"
	ip route show table main
	echo "--------------------"
	echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR INFO] 'ip rule' output:"
	echo "--------------------"
	ip rule
	echo "--------------------"
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR INFO] 'netstat -lpn' output:"
	echo "--------------------"
	netstat -lpn
	echo "--------------------"
}
