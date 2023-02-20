#!/usr/bin/env sh

SCRIPT_NAME=${0}
COMMAND=${1}
SELECTED_VERSION=${2:-"-1"}
PERSISTENT_ROOT="/mnt/data"
IP_RULE_MONITOR_PID_FILE="/run/ip-rule-monitor.pid"
WAN_FAILOVER_MONITOR_PID_FILE="/run/wan-failover-monitor.pid"
UNIFIOS_TAILSCALE_ROOT="${UNIFIOS_TAILSCALE_ROOT:-${PERSISTENT_ROOT}/unifios-tailscale}"
TAILSCALE="${UNIFIOS_TAILSCALE_ROOT}/tailscale"
TAILSCALED="${UNIFIOS_TAILSCALE_ROOT}/tailscaled"
TAILSCALED_SOCK="${TAILSCALED_SOCK:-/var/run/tailscale/tailscaled.sock}"
TAILSCALED_LOG_FILE="${UNIFIOS_TAILSCALE_ROOT}/tailscaled.log"
. "${UNIFIOS_TAILSCALE_ROOT}/.env"
SUBNETS=$(ip route | grep br | cut -d ' ' -f 1 | tr '\n' ',' | rev | cut -c2- | rev)
DEFAULT_TAILSCALE_FLAGS="--advertise-exit-node --advertise-routes=${SUBNETS} --snat-subnet-routes=false --accept-routes --reset"
TAILSCALE_FLAGS="${TAILSCALE_FLAGS:-${DEFAULT_TAILSCALE_FLAGS}}"

install_tailscale() {
    #get latest Tailscale version number
    ARG1=${1}
    if [ "x${1}" = "x-1" ]
    then
        unset ARG1
    fi
    LATEST_TAILSCALE_VERSION="${ARG1:-$(curl -sSLq --ipv4 'https://pkgs.tailscale.com/stable/?mode=json' | jq -r '.Tarballs.arm64 | capture("tailscale_(?<version>[^_]+)_").version')}"

    #create temporary directory
    TMP="$(mktemp -d || exit 1)"

    #path to Tailscale tarball
    TAILSCALE_TARBALL="${TMP}/tailscale.tgz"

    #delete temporary directory when finished
    trap 'rm -rf ${TMP}' EXIT

    echo "Tailscale v${LATEST_TAILSCALE_VERSION} is being installed in ${UNIFIOS_TAILSCALE_ROOT}..."

    #download Tailscale tarball
    curl -sSLf --ipv4 -o "${TAILSCALE_TARBALL}" "https://pkgs.tailscale.com/stable/tailscale_${LATEST_TAILSCALE_VERSION}_arm64.tgz" || {
        echo "Tailscale v${LATEST_TAILSCALE_VERSION} failed to download from https://pkgs.tailscale.com/stable/tailscale_${LATEST_TAILSCALE_VERSION}_arm64.tgz"
        echo "Ensure v${LATEST_TAILSCALE_VERSION} is a valid version and try again."

        exit 1
    }

    #extract Tailscale to temporary directory
    tar xzf "${TAILSCALE_TARBALL}" -C "${TMP}"

    #create Tailscale installation directory
    mkdir -p "${UNIFIOS_TAILSCALE_ROOT}"

    #stop tailscale if a restart was requested by second parameter
    if [ "x${2}" = "xRESTART" ]
    then
        stop_unifios_tailscale
    fi

    #copy Tailscale files to installation directory
    cp "${TMP}/tailscale_${LATEST_TAILSCALE_VERSION}_arm64"/* "${UNIFIOS_TAILSCALE_ROOT}"

    #copy launch file to automatically start unifios-tailscale
    cp "${UNIFIOS_TAILSCALE_ROOT}/10-unifios-tailscale.sh" "${PERSISTENT_ROOT}/on_boot.d"

    #notify user that installation is complete
    echo "Installation of Tailscale is complete."

    #start tailscale if a restart was requested by second parameter
    if [ "x${2}" = "xRESTART" ]
    then
        start_unifios_tailscale
    else
        echo "Run '${SCRIPT_NAME} start' to start unifios-tailscale."
    fi

}

start_unifios_tailscale() {
    echo "Starting unifios-tailscale..."

    #link logrotate configuration file to /etc/logrotate.d
    ln -s ${UNIFIOS_TAILSCALE_ROOT}/tailscale_logrotate.conf /etc/logrotate.d/tailscale_logrotate || true

    #start script that monitors changes to ip rules and marks all Tailscale packets
    ${UNIFIOS_TAILSCALE_ROOT}/ip-rule-monitor.sh > /dev/null 2>&1 &

    #save the process id of ip-rule-monitor.sh to a file so that this script can stop it at a later time
    echo ${!} > "${IP_RULE_MONITOR_PID_FILE}"

    #start script that notifies of failover events
    ${UNIFIOS_TAILSCALE_ROOT}/wan-failover-monitor.sh > /dev/null 2>&1 &

    #save the process id of wan-failover-monitor.sh to a file so that this script can stop it at a later time
    echo ${!} > "${WAN_FAILOVER_MONITOR_PID_FILE}"

    #add local networks to tailscale routing table to avoid traffic being wrongly sent over tailscale0
    ROUTES_TO_ADD=$( ip route | grep "dev br" )
    echo "${ROUTES_TO_ADD}" | while read -r route; do /sbin/ip route add ${route} table 52; done

    #launch tailscaled
    setsid $TAILSCALED \
        --port "${PORT}" \
        --socket "${TAILSCALED_SOCK}" \
        --state "${UNIFIOS_TAILSCALE_ROOT}/tailscaled.state" \
        ${TAILSCALED_FLAGS} >> "${TAILSCALED_LOG_FILE}" 2>&1 &

    # Wait a few seconds for the daemon to start
    sleep 5

    if [ -e "${TAILSCALED_SOCK}" ]; then
        echo "unifios-tailscale started successfully."
    else
        echo "unifios-tailscale failed to start."

        exit 1
    fi

    # Run tailscale up to configure
    echo "Running tailscale up to configure interface..."
    timeout 5 ${TAILSCALE} --socket ${TAILSCALED_SOCK} up $TAILSCALE_FLAGS
}

stop_unifios_tailscale() {
    echo "Stopping unifios-tailscale..."

    #run tailscale down
    ${TAILSCALE} down || true

    #kill all tailscaled processes
    killall tailscaled 2> /dev/null || true

    #run tailscaled cleanup
    ${TAILSCALED} --cleanup

    #get the process id of ip-rule-monitor.sh
    read IP_RULE_MONITOR_PID < "${IP_RULE_MONITOR_PID_FILE}"

    #get the process id of wan-failover-monitor.sh
    read WAN_FAILOVER_MONITOR_PID < "${WAN_FAILOVER_MONITOR_PID_FILE}"

    #kill ip-rule-monitor.sh
    pkill -f "ip-rule-monitor.sh" || true

    #kill wan-failover-monitor.sh
    pkill -f "wan-failover-monitor.sh" || true

    #delete ip-rule-monitor.sh process id file
    rm ${IP_RULE_MONITOR_PID_FILE}

    #delete wan-failover-monitor.sh process id file
    rm ${WAN_FAILOVER_MONITOR_PID_FILE}

    #remove local network routes by flushing the route table used by Tailscale
    /sbin/ip route flush table 52
}

tailscale_status() {
    if [ -e "${TAILSCALED_SOCK}" ]
    then
        echo "unifios-tailscale is running."
        ${TAILSCALE} --version

        return 0
    else
        echo "unifios-tailscale is not running."

        return 1
    fi
}

tailscale_upgrade_available() {
    #get the version number of the currently installed Tailscale
    CURRENT_VERSION="$(${TAILSCALE} --version | head -n 1)"

    #use this function's first agrument to get the version number or get the most recently available version of Tailscale
    ARG1="${1}"
    if [ "x${1}" = "x-1" ]
    then
        unset ARG1
    fi
    TARGET_TAILSCALE_VERSION="${ARG1:-$(curl -sSLq --ipv4 'https://pkgs.tailscale.com/stable/?mode=json' | jq -r '.Tarballs.arm64 | capture("tailscale_(?<version>[^_]+)_").version')}"
    
    if [ "${CURRENT_VERSION}" != "${TARGET_TAILSCALE_VERSION}" ] || [ "x${3}" = "xIGNOREVERSION" ]
    then
        echo "TRUE"
    else
        echo "FALSE"
    fi
}

upgrade_tailscale() {
    # if [ $(tailscale_upgrade_available "${1}" "${3}") ]
    TAILSCALE_UPGRADE_AVAILABLE=$( tailscale_upgrade_available "${1}" "${2}" "${3}" )
    if [ "x${TAILSCALE_UPGRADE_AVAILABLE}" = "xTRUE" ]
    then
        if [ -e "${TAILSCALED_SOCK}" ] && [ "x${2}" != "xFORCERESTART" ]
        then
            echo "Upgrade has been aborted because unifios-tailscale is running. If you want to restart it during an upgrade, run '${SCRIPT_NAME} upgrade!'."

            exit 1
        fi

        install_tailscale "${1}" "RESTART"
    else
        echo "Tailscale is already up to date."
    fi
}

uninstall_tailscale() {
    echo "Removing Tailscale..."

    #run tailscaled cleanup
    ${TAILSCALED} --cleanup

    #remove unifios-tailscale installation directory
    rm -rf ${UNIFIOS_TAILSCALE_ROOT}

    #remove auto-startup file
    rm -f ${PERSISTENT_ROOT}/on_boot.d/10-unifios-tailscale.sh
}



case ${COMMAND} in
    "status")
        tailscale_status
        ;;
    "start")
        start_unifios_tailscale
        ;;
    "stop")
        stop_unifios_tailscale
        ;;
    "restart")
        stop_unifios_tailscale
        start_unifios_tailscale
        ;;
    "install")
        if [ -e "${TAILSCALE}" ]
        then
            echo "Tailscale is already installed. Run '${SCRIPT_NAME} upgrade' to upgrade it."

            exit 0
        fi

        install_tailscale "${SELECTED_VERSION}"
        ;;
    "upgrade")
        upgrade_tailscale "${SELECTED_VERSION}"
        ;;
    "upgrade!")
        upgrade_tailscale "${SELECTED_VERSION}" "FORCERESTART"
        ;;
    "forceupgrade")
        upgrade_tailscale "${SELECTED_VERSION}" "FORCERESTART" "IGNOREVERSION"
        ;;
    "uninstall")
        stop_unifios_tailscale
        uninstall_tailscale
        ;;
    "autostart")
        . "${UNIFIOS_TAILSCALE_ROOT}/.env"

        if [ "${AUTOMATICALLY_UPGRADE_TAILSCALE}" = "true" ]; then
            tailscale_upgrade_available && upgrade_tailscale || echo "Tailscale was not upgraded."
        fi

        start_unifios_tailscale
        ;;
    *)
        echo "Usage: ${SCRIPT_NAME} {status|start|stop|restart|install|uninstall|upgrade|upgrade!|forceupgrade|autostart}"
        exit 1
        ;;
esac
